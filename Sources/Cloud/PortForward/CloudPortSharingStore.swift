import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// Who can reach each Cloud machine port beyond its private preview, for every
/// surface that shows it: the Ports rows' audience badge, the port menu, and the
/// preview tab's share control. One `listPublications` call covers every
/// machine, so the store keeps one list. Rows ask for a refresh when they
/// appear; `CloudPortSharingFreshness` turns those asks into at most one read per
/// TTL. Any share change (this app's controls or a `cmux` CLI write through the
/// socket) invalidates it, so the badges follow the change without polling.
@MainActor
@Observable
final class CloudPortSharingStore {
    static let shared = CloudPortSharingStore()

    /// Every publication the account can see, as last read.
    private(set) var publications: [CloudPortPublicationRef] = []
    /// False until the first read lands; badges stay hidden rather than guess.
    private(set) var hasLoaded = false

    @ObservationIgnored private var freshness: CloudPortSharingFreshness
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private let fetch: @MainActor () async throws -> [CloudPortPublicationRef]
    @ObservationIgnored private let now: () -> Date

    init(
        freshness: CloudPortSharingFreshness = CloudPortSharingFreshness(),
        now: @escaping () -> Date = Date.init,
        fetch: @escaping @MainActor () async throws -> [CloudPortPublicationRef] = CloudPortSharingStore.fetchFromCloud
    ) {
        self.freshness = freshness
        self.now = now
        self.fetch = fetch
    }

    /// The port's audience, or nil until publications have been read once.
    func sharing(machineID: String, port: Int) -> CloudPortSharing? {
        hasLoaded ? plan(machineID: machineID, port: port).current : nil
    }

    func plan(machineID: String, port: Int) -> CloudPortSharePlan {
        CloudPortSharePlan(publications: publications, machineID: machineID, port: port)
    }

    /// Reads publications in the background when the policy says the list is stale.
    func requestRefresh() {
        guard freshness.shouldFetch(now: now()) else { return }
        let token = freshness.begin()
        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let list = try await self.fetch()
                self.accept(list, token: token)
            } catch {
                self.freshness.fail(now: self.now())
            }
            self.fetchTask = nil
        }
    }

    /// A fresh read before a share decision: waits for a read already in flight,
    /// then reads again so the plan never acts on a list from before a change.
    @discardableResult
    func reload() async throws -> [CloudPortPublicationRef] {
        if let fetchTask { await fetchTask.value }
        let token = freshness.begin()
        do {
            let list = try await fetch()
            accept(list, token: token)
            return list
        } catch {
            freshness.fail(now: now())
            throw error
        }
    }

    /// A publication changed somewhere: read again now, ignoring TTL and backoff.
    func invalidate() {
        freshness.invalidate()
        requestRefresh()
    }

    /// Socket writes (`cmux cloud domains`, `cmux vm share`) land here after they succeed.
    nonisolated static func publicationsDidChange() async {
        await MainActor.run { CloudPortSharingStore.shared.invalidate() }
    }

    private func accept(_ list: [CloudPortPublicationRef], token: Int) {
        freshness.succeed(token: token, now: now())
        if publications != list { publications = list }
        if !hasLoaded { hasLoaded = true }
    }

    static func fetchFromCloud() async throws -> [CloudPortPublicationRef] {
        guard let client = VMClient.shared else { throw CloudPortShareError.signedOut }
        return try await client.listPublications().map(CloudPortPublicationRef.init)
    }
}

enum CloudPortShareError: Error, CustomStringConvertible {
    case signedOut
    case mutationDidNotConverge

    var description: String {
        switch self {
        case .signedOut:
            return String(localized: "cloudPort.share.signedOut", defaultValue: "Sign in to cmux Cloud to share a port.")
        case .mutationDidNotConverge:
            return String(localized: "cloudPort.share.changeFailed", defaultValue: "Could not change who can open the port")
        }
    }
}

extension CloudPortPublicationRef {
    init(_ publication: VMPublication) {
        self.init(
            id: publication.id,
            hostname: publication.hostname,
            url: publication.url,
            vmID: publication.vmID,
            port: publication.port,
            sharing: CloudPortSharing(accessMode: publication.accessMode.rawValue),
            isGeneratedDomain: publication.domainKind == "generated",
            isActive: publication.state.lowercased() != "disabled" && publication.state.lowercased() != "deleted"
        )
    }
}

extension CloudPortShareAudience {
    var accessMode: VMPublicationAccessMode {
        switch self {
        case .personal: .personal
        case .team: .team
        case .public: .public
        }
    }
}
