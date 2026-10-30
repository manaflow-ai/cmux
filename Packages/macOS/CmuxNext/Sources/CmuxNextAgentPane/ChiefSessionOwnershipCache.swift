public import Foundation
import CmuxNextCompat

/// Caches one Chief-home session census for a launch warm batch. The cache keeps the
/// ownership lookup off the per-chat path while preserving the disk fallback when the Chief
/// socket is stopped or still starting.
package actor ChiefSessionOwnershipCache {
    private let socket: String?
    private let home: URL?
    private let parentTag: String
    private let fileExists: @Sendable (String) -> Bool
    private var owned: Set<String>?
    private var attempted = false

    /// Creates a census scoped to one warm call, with a replaceable filesystem probe.
    package init(socket: String?, home: URL?, parentTag: String,
                 fileExists: @escaping @Sendable (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) }) {
        self.socket = socket
        self.home = home
        self.parentTag = parentTag
        self.fileExists = fileExists
    }

    /// Resolves membership from one listing, or the durable session directory when unavailable.
    package func owns(_ session: String) async -> Bool {
        if let owned { return owned.contains(session) }
        if !attempted {
            attempted = true
            if let socket, fileExists(socket),
               let response = try? await AcpmuxStatusClient.sessions(socketPath: socket, deadline: .seconds(2)) {
                let rows = response.value["sessions"] as? [[String: Any]] ?? []
                let owned = Set(rows.compactMap { row -> String? in
                    guard (row["tags"] as? [String: Any])?["mux.parent"] as? String == parentTag else { return nil }
                    return row["sessionId"] as? String
                })
                self.owned = owned
                return owned.contains(session)
            }
        }
        return AcpmuxChiefSessionRouter.keeps(session: session, home: home)
    }
}
