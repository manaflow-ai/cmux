import Foundation

// MARK: - Port sharing: one plan for the app's share control and `cmux vm share`

/// One publication of a machine port, reduced to what sharing decisions need.
/// The app builds it from `VMPublication`, the CLI from the `vm.publication_list`
/// payload, so both read and change a port's audience through the same plan.
public struct CloudPortPublicationRef: Equatable, Sendable {
    public let id: String
    public let hostname: String
    public let url: String
    public let vmID: String
    public let port: Int
    public let sharing: CloudPortSharing
    /// A generated `<vm>--<org>--<port>.cmux.sh` name. A custom domain is
    /// configuration the person set up, so Stop Sharing narrows it instead of
    /// deleting it.
    public let isGeneratedDomain: Bool
    /// Whether the publication is active. Disabled rows can remain briefly in
    /// an authoritative list after a failed or completed mutation; they no
    /// longer admit traffic and must not keep a port looking shared.
    public let isActive: Bool

    public init(
        id: String,
        hostname: String,
        url: String,
        vmID: String,
        port: Int,
        sharing: CloudPortSharing,
        isGeneratedDomain: Bool,
        isActive: Bool = true
    ) {
        self.id = id
        self.hostname = hostname
        self.url = url
        self.vmID = vmID
        self.port = port
        self.sharing = sharing
        self.isGeneratedDomain = isGeneratedDomain
        self.isActive = isActive
    }

    /// Reads one `vm.publication_list` row (the socket's `VMPublication.foundationObject`).
    /// Rows without an id or a port are skipped by returning nil.
    public init?(foundationObject object: [String: Any]) {
        guard let id = object["id"] as? String, !id.isEmpty,
              let vmID = object["vmId"] as? String,
              let port = Self.int(object["port"]) ?? Self.int(object["targetPort"]) else { return nil }
        let hostname = (object["hostname"] as? String) ?? ""
        self.init(
            id: id,
            hostname: hostname,
            url: (object["url"] as? String) ?? (hostname.isEmpty ? "" : "https://\(hostname)"),
            vmID: vmID,
            port: port,
            sharing: CloudPortSharing(accessMode: object["accessMode"] as? String),
            isGeneratedDomain: ((object["domainKind"] as? String) ?? "generated") == "generated",
            isActive: Self.isActiveState(object["state"] as? String)
        )
    }

    private static func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private static func isActiveState(_ state: String?) -> Bool {
        guard let state else { return true }
        return state.lowercased() != "disabled" && state.lowercased() != "deleted"
    }
}

/// Who a shared link admits. `Only you` still needs a sign-in, `team` admits the
/// owning team, `public` admits anyone with the link.
public enum CloudPortShareAudience: String, CaseIterable, Equatable, Sendable {
    case personal
    case team
    case `public`

    public var sharing: CloudPortSharing {
        switch self {
        case .personal: .personal
        case .team: .team
        case .public: .public
        }
    }
}

/// What a share control or `cmux vm share` asks for.
public enum CloudPortShareTarget: Equatable, Sendable {
    /// Give the port a link with this audience (creating one when it has none).
    case audience(CloudPortShareAudience)
    /// Back to the private preview only: generated links are removed, custom
    /// domains keep their hostname but admit only the owner.
    case stopSharing
}

/// One write the plan needs. Creating a public link is two writes for the
/// executor (create privately, then open), so a failure never leaves it public.
public enum CloudPortShareStep: Equatable, Sendable {
    case create(CloudPortShareAudience)
    case update(id: String, CloudPortShareAudience)
    case delete(id: String)
}

/// A port's publications and the writes that bring all of them to one audience.
/// A port can carry several publications (a CLI publish plus a menu share, or a
/// custom domain beside the generated one), so its status is the widest audience
/// among them and a chosen audience applies to every one: narrowing one link
/// while another stays public would report a private port anyone can still open.
public struct CloudPortSharePlan: Equatable, Sendable {
    /// The port's publications, widest audience first, then in listed order.
    public let publications: [CloudPortPublicationRef]

    public init(publications: [CloudPortPublicationRef], machineID: String, port: Int) {
        self.publications = publications
            .filter { $0.isActive && $0.vmID == machineID && $0.port == port }
            .enumerated()
            .sorted {
                let left = $0.element.sharing.breadth
                let right = $1.element.sharing.breadth
                return left != right ? left > right : $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// The widest audience any publication of the port has; `unshared` with none.
    public var current: CloudPortSharing { CloudPortSharing.widest(publications.map(\.sharing)) }

    /// Whether the port has any link at all.
    public var isShared: Bool { !publications.isEmpty }

    /// The link a control shows and copies: the widest publication's.
    public var primary: CloudPortPublicationRef? { publications.first }

    /// The audience the share control marks as chosen; nil while the port has no link.
    public var selectedAudience: CloudPortShareAudience? {
        switch current {
        case .unshared: nil
        case .personal: .personal
        case .team: .team
        case .public: .public
        }
    }

    /// Whether reaching `target` makes the port public when it is not already;
    /// only then is the explicit "anyone with the link" confirmation required.
    public func requiresPublicConfirmation(_ target: CloudPortShareTarget) -> Bool {
        target == .audience(.public) && current != .public
    }

    /// The writes that bring every publication of the port to `target`, widest first.
    /// Empty when the port is already there.
    public func steps(to target: CloudPortShareTarget) -> [CloudPortShareStep] {
        switch target {
        case .audience(let audience):
            guard isShared else { return [.create(audience)] }
            return publications
                .filter { $0.sharing != audience.sharing }
                .map { .update(id: $0.id, audience) }
        case .stopSharing:
            return publications.compactMap { publication in
                if publication.isGeneratedDomain { return .delete(id: publication.id) }
                return publication.sharing == .personal ? nil : .update(id: publication.id, .personal)
            }
        }
    }

    /// Custom domains Stop Sharing keeps (narrowed to the owner) instead of deleting.
    public var customDomainsKeptByStopSharing: [CloudPortPublicationRef] {
        publications.filter { !$0.isGeneratedDomain }
    }
}

/// When the shared publication list is worth reading again. Rows ask on appear;
/// the policy turns that into at most one request per `ttl`, none while one is in
/// flight, and none for `failureBackoff` after a failure, so a tree full of port
/// rows never becomes a request storm. A share change invalidates it at once.
public struct CloudPortSharingFreshness: Equatable, Sendable {
    public let ttl: TimeInterval
    public let failureBackoff: TimeInterval
    public private(set) var loadedAt: Date?
    public private(set) var failedAt: Date?
    public private(set) var isFetching = false
    /// Bumped by every invalidation, so a read that started before a share change
    /// cannot mark the list fresh.
    public private(set) var generation = 0
    private var freshGeneration: Int?

    public init(ttl: TimeInterval = 120, failureBackoff: TimeInterval = 30) {
        self.ttl = ttl
        self.failureBackoff = failureBackoff
    }

    public var hasLoaded: Bool { loadedAt != nil }

    public func shouldFetch(now: Date) -> Bool {
        guard !isFetching else { return false }
        if let failedAt, now.timeIntervalSince(failedAt) < failureBackoff { return false }
        guard let loadedAt, freshGeneration == generation else { return true }
        return now.timeIntervalSince(loadedAt) >= ttl
    }

    /// Starts a read and returns its token for `succeed`/`fail`.
    public mutating func begin() -> Int {
        isFetching = true
        return generation
    }

    public mutating func succeed(token: Int, now: Date) {
        isFetching = false
        failedAt = nil
        loadedAt = now
        freshGeneration = token
    }

    public mutating func fail(now: Date) {
        isFetching = false
        failedAt = now
    }

    /// A share changed: the next ask reads again, even inside the TTL or backoff.
    public mutating func invalidate() {
        generation += 1
        failedAt = nil
    }
}
