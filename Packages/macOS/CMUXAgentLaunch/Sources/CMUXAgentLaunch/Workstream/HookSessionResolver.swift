import Foundation

/// Reads the per-agent hook session stores (`~/.cmuxterm/<agent>-hook-sessions.json`)
/// to map a feed `workstream_id` back to a cmux `(workspaceId, surfaceId)` pair.
/// The schema is the same one written by `cmux <agent>-hook session-start`.
///
/// Replaces the former caseless `FeedJumpResolver` namespace-enum: the disk
/// reader is an injectable value type so tests can point resolution at a
/// temporary `~/.cmuxterm`. `focus` and `sendText` post the existing cmux
/// `Notification.Name` intents (see below) so the Feed layer stays decoupled
/// from `TerminalController`'s V2 handlers; the observer lives in `AppDelegate`.
public struct HookSessionResolver {
    /// A resolved feed target: the cmux workspace and surface a hook session
    /// is bound to.
    public struct Target: Equatable {
        public let workspaceId: String
        public let surfaceId: String

        public init(workspaceId: String, surfaceId: String) {
            self.workspaceId = workspaceId
            self.surfaceId = surfaceId
        }
    }

    private let fileManager: FileManager

    /// Creates a resolver.
    ///
    /// - Parameter fileManager: Injected so tests can point resolution at a
    ///   temporary home directory; defaults to `.default`.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Splits a `workstreamId` of the form `<agent>-<sessionId>` into its
    /// agent and session components, or `nil` when either side is empty.
    public func parse(_ workstreamId: String) -> (agent: String, sessionId: String)? {
        guard let dash = workstreamId.firstIndex(of: "-") else { return nil }
        let agent = String(workstreamId[..<dash])
        let sessionId = String(workstreamId[workstreamId.index(after: dash)...])
        guard !agent.isEmpty, !sessionId.isEmpty else { return nil }
        return (agent, sessionId)
    }

    /// Looks up the matching hook-session entry in
    /// `~/.cmuxterm/<agent>-hook-sessions.json` (written by
    /// `cmux <agent>-hook session-start`) and returns its bound
    /// `(workspaceId, surfaceId)`, or `nil` when no usable entry exists.
    public func lookup(agent: String, sessionId: String) -> Target? {
        let home = fileManager.homeDirectoryForCurrentUser
        let file = home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("\(agent)-hook-sessions.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Stores have a consistent shape: top-level `sessions` dict keyed
        // by sessionId. Tolerate older flat layouts too.
        let sessions: [String: Any]
        if let nested = root["sessions"] as? [String: Any] {
            sessions = nested
        } else {
            sessions = root
        }
        guard let entry = sessions[sessionId] as? [String: Any],
              let workspaceId = entry["workspaceId"] as? String,
              let surfaceId = entry["surfaceId"] as? String,
              !workspaceId.isEmpty, !surfaceId.isEmpty
        else { return nil }
        return Target(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// Dispatches a workspace-select + surface-focus intent. Posts
    /// through the existing cmux notification pathway so we don't need
    /// to bind directly to the TerminalController V2 handlers from the
    /// Feed layer.
    @MainActor
    public func focus(workspaceId: String, surfaceId: String) {
        NotificationCenter.default.post(
            name: .feedRequestFocus,
            object: nil,
            userInfo: [
                "workspaceId": workspaceId,
                "surfaceId": surfaceId,
            ]
        )
    }

    /// Dispatches a surface.send_text intent for the agent's terminal.
    /// The observer in AppDelegate translates it into the V2 socket
    /// call so the Feed stays decoupled from TerminalController.
    @MainActor
    public func sendText(workspaceId: String, surfaceId: String, text: String) {
        NotificationCenter.default.post(
            name: .feedRequestSendText,
            object: nil,
            userInfo: [
                "workspaceId": workspaceId,
                "surfaceId": surfaceId,
                "text": text,
            ]
        )
    }
}

extension Notification.Name {
    /// Posted by `HookSessionResolver.focus` to ask the app to select a
    /// workspace and focus a surface; observed in `AppDelegate`.
    public static let feedRequestFocus = Notification.Name("cmux.feedRequestFocus")
    /// Posted by `HookSessionResolver.sendText` to ask the app to type text
    /// into an agent's surface; observed in `AppDelegate`.
    public static let feedRequestSendText = Notification.Name("cmux.feedRequestSendText")
}
