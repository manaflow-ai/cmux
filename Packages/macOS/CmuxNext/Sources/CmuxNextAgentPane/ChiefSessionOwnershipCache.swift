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
    private var listing: [String: Any]?

    package init(socket: String?, home: URL?, parentTag: String,
                 fileExists: @escaping @Sendable (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) }) {
        self.socket = socket
        self.home = home
        self.parentTag = parentTag
        self.fileExists = fileExists
    }

    package func owns(_ session: String) async -> Bool {
        if let listing { return AcpmuxChiefSessionRouter.owns(listing, session: session, parentTag: parentTag) }
        if let socket, fileExists(socket),
           let response = try? await AcpmuxStatusClient.sessions(socketPath: socket, deadline: .seconds(2)) {
            listing = response.value
            return AcpmuxChiefSessionRouter.owns(response.value, session: session, parentTag: parentTag)
        }
        return AcpmuxChiefSessionRouter.keeps(session: session, home: home)
    }
}
