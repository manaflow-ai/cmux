import Foundation

extension AppStore {
    /// A Mac removed from the account (here, or on another device): gone
    /// from every team, its workspaces, data and connection state, and the
    /// stored preferences that pointed at it (the Mac the link dials per
    /// team, the Workspaces Mac filter, the preferred Mac for new
    /// workspaces). Returns false when the store did not know it.
    @discardableResult
    public func forgetMac(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        var known = false
        for index in teams.indices where teams[index].macs.contains(where: { $0.id == id }) {
            teams[index].macs.removeAll { $0.id == id }
            known = true
        }
        let gone = workspaces.filter { $0.macID == id }.map(\.id)
        if !gone.isEmpty {
            known = true
            for workspaceID in gone {
                removeWorkspace(workspaceID)
                if isPending(workspaceID) { removePending(workspaceID) }
            }
        }
        if macData.removeValue(forKey: id) != nil { known = true }
        if macConnection.removeValue(forKey: id) != nil { known = true }
        if macLinkStatus.removeValue(forKey: id) != nil { known = true }
        if macLinkDiagnostics.removeValue(forKey: id) != nil { known = true }
        if known, let count = accountMacCount, count > 0 { accountMacCount = count - 1 }
        for (key, value) in defaults.dictionaryRepresentation() where Self.isAccountPreference(key) && value as? String == id {
            defaults.removeObject(forKey: key)
        }
        return known
    }
}

/// Macs this phone removed, against service answers that were already
/// on their way when the delete finished: such a Mac list (or discovery
/// reply) still names the Mac and would bring it back until the next
/// refresh. Take `mark` before asking; `filter` then drops only Macs
/// removed after that. A list asked for after the removal is the truth,
/// including a Mac that registered again (cmux on it signed in again: a
/// new registration, PROTOCOL.md).
public struct RemovedMacs: Equatable, Sendable {
    private var serial = 0
    private var removedAt: [String: Int] = [:]

    public init() {}

    /// The point a request is sent at.
    public var mark: Int { serial }

    public mutating func removed(_ id: String) {
        serial += 1
        removedAt[id] = serial
    }

    /// Whether `id` was removed after `mark`.
    public func removedSince(_ mark: Int, id: String) -> Bool {
        (removedAt[id] ?? 0) > mark
    }

    /// The list without Macs removed after it was asked for (at `mark`).
    public func filter<Mac>(_ macs: [Mac], askedAt mark: Int, id: (Mac) -> String) -> [Mac] {
        guard serial > mark else { return macs }
        return macs.filter { !removedSince(mark, id: id($0)) }
    }
}

/// A Cloud service failure as a screen shows it: what went wrong in plain
/// words, and the service's Request ID for support when it sent one.
public struct ServiceFailureMessage: Error, Equatable, Sendable {
    public var text: String
    public var requestID: String?

    public init(text: String, requestID: String? = nil) {
        self.text = text
        self.requestID = requestID
    }

    /// The alert body: the text, then the Request ID on its own line.
    public var display: String {
        guard let requestID else { return text }
        return "\(text)\n\nRequest ID: \(requestID)"
    }
}
