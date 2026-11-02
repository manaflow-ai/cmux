import Foundation
import Observation

/// The chats muted on this phone (Mute Chat Notifications), as the app's menus read them. The
/// shell loads it from, and saves it to, the store its notification extension reads
/// (`PushChatMutes`), off any view update; menus read the set in memory.
@MainActor
@Observable
public final class ChatMuteList {
    public static let shared = ChatMuteList()

    /// `mac|session` keys (`PushChatMutes.key`).
    public private(set) var keys: Set<String> = []
    /// Saves a changed list (set by the shell).
    @ObservationIgnored public var save: (@MainActor (Set<String>) -> Void)?

    public init() {}

    public static func key(mac: String, session: String) -> String { "\(mac.lowercased())|\(session)" }

    /// The stored list, at launch.
    public func load(_ keys: Set<String>) {
        if self.keys != keys { self.keys = keys }
    }

    public func isMuted(mac: String, session: String) -> Bool {
        keys.contains(Self.key(mac: mac, session: session))
    }

    public func setMuted(_ on: Bool, mac: String, session: String) {
        let key = Self.key(mac: mac, session: session)
        guard on != keys.contains(key) else { return }
        if on { keys.insert(key) } else { keys.remove(key) }
        save?(keys)
    }
}

/// The acpmux session an agent tab shows, as its Mac's tree binds it: what a chat's pushes
/// name (`sessionId`), so a mute set on the tab matches them.
@MainActor
public protocol ChatSessionNaming: AnyObject {
    func agentSessionID(of tab: WorkspaceTab, in workspace: Workspace) -> String?
}

#if DEBUG
extension MockWorkspaceCreationBackend: ChatSessionNaming {
    public func agentSessionID(of tab: WorkspaceTab, in workspace: Workspace) -> String? {
        tab.kind == .agent ? "session-\(tab.id)" : nil
    }
}
#endif
