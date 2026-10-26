/// One diagnostic site the daemon saw for the first time in its life, from its `server-diagnostic-site` event
/// (cmux-tui spec/events.md, p02-threads-233): a blocking call on a daemon thread that disallows blocking, a
/// wait on lower-QoS work, or a request method that ran past the daemon's 250 ms watchdog. The daemon's half
/// of the app's ``BlockingViolation``: it goes to the same hang report sink, with the daemon as its source.
///
/// It carries no path: a blocking site is its crate, a 16-hex-digit hash of its file and its line. Decoding
/// refuses a value outside those shapes (a label of other characters, a hash that is not 16 hex digits), so
/// nothing a report or a crash report copies from it can hold a path, a name or user text.
public struct DaemonDiagnosticSite: Sendable, Hashable, Decodable {
    /// The event's wire name.
    public static let eventName = "server-diagnostic-site"
    /// The longest label (`kind`, `crate`, `method`) the app keeps.
    public static let maxLabelLength = 64

    /// What the site is.
    public enum Family: String, Sendable, Hashable, Decodable {
        /// A blocking call where blocking is disallowed, or a work item's wait for other work (``laneSync``).
        case blocking
        /// A wait on work that runs at a lower QoS than the waiter.
        case inversion
        /// A request method that ran past the watchdog threshold.
        case hang
    }

    /// What the site is.
    public var family: Family
    /// The daemon's kind name (`fs`, `recv`, `priority-inversion`, ...), or `request` for a hang.
    public var kind: String
    /// Blocking and inversion: the call site's crate (`cmux-tui-core`, `tokio`, `other`).
    public var crateName: String?
    /// Blocking and inversion: 16 hex digits, the hash of the call site's file.
    public var fileHash: String?
    /// Blocking and inversion: the call site's line.
    public var line: UInt32?
    /// Blocking: a work item's wait for other work.
    public var laneSync: Bool
    /// Hang: the request's command or operation name (`list-workspaces`, `frame.apps`).
    public var method: String?

    private enum CodingKeys: String, CodingKey {
        case family, kind, line, method
        case crateName = "crate"
        case fileHash = "file_hash"
        case laneSync = "lane_sync"
    }

    /// Why a decoded value was refused.
    public enum Refusal: Error, Equatable {
        /// `field` is not a short lowercase label.
        case label(field: String)
        /// `file_hash` is not 16 lowercase hex digits.
        case fileHash
        /// A blocking or inversion site without crate, hash and line, or a hang without its method.
        case incomplete
    }

    /// Makes the value from its parts, checking them as decoding does.
    public init(family: Family, kind: String, crateName: String? = nil, fileHash: String? = nil, line: UInt32? = nil,
                laneSync: Bool = false, method: String? = nil) throws(Refusal) {
        guard Self.isLabel(kind) else { throw .label(field: "kind") }
        if let crateName, !Self.isLabel(crateName) { throw .label(field: "crate") }
        if let method, !Self.isLabel(method) { throw .label(field: "method") }
        if let fileHash, !Self.isFileHash(fileHash) { throw .fileHash }
        switch family {
        case .blocking, .inversion:
            guard crateName != nil, fileHash != nil, line != nil else { throw .incomplete }
        case .hang:
            guard method != nil else { throw .incomplete }
        }
        self.family = family
        self.kind = kind
        self.crateName = crateName
        self.fileHash = fileHash
        self.line = line
        self.laneSync = laneSync
        self.method = method
    }

    /// Reads one event line's fields; a value outside their shapes is a decoding error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let family = try container.decode(Family.self, forKey: .family)
        let kind = try container.decode(String.self, forKey: .kind)
        let crateName = try container.decodeIfPresent(String.self, forKey: .crateName)
        let fileHash = try container.decodeIfPresent(String.self, forKey: .fileHash)
        let line = try container.decodeIfPresent(UInt32.self, forKey: .line)
        let laneSync = try container.decodeIfPresent(Bool.self, forKey: .laneSync) ?? false
        let method = try container.decodeIfPresent(String.self, forKey: .method)
        let site: DaemonDiagnosticSite
        do {
            site = try DaemonDiagnosticSite(family: family, kind: kind, crateName: crateName, fileHash: fileHash, line: line,
                                            laneSync: laneSync, method: method)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "server-diagnostic-site refused: \(error)"))
        }
        self = site
    }

    /// The site's identity across daemon lives and launches: a blocking or inversion site by crate, file and
    /// line (whatever kind the daemon saw first), a hang by its method.
    public var key: String {
        switch family {
        case .blocking, .inversion: "daemon-\(crateName ?? "")-\(fileHash ?? "")-\(line.map(String.init) ?? "")"
        case .hang: "daemon-hang-\(method ?? "")"
        }
    }

    /// A lowercase letter, then lowercase letters, digits, `-`, `_` and `.`, at most ``maxLabelLength``.
    static func isLabel(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...maxLabelLength).contains(bytes.count), let first = bytes.first, (0x61...0x7A).contains(first) else {
            return false
        }
        return bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E }
    }

    static func isFileHash(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 16 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
