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
    /// Saves a changed list (set by the shell; it writes them in order, newest last).
    @ObservationIgnored public var save: (@MainActor (Set<String>) -> Void)?
    /// Changes made before the stored list loaded: applied on top of it, so a launch-time
    /// read never undoes a mute or unmute the person already made.
    @ObservationIgnored private var early: [String: Bool]? = [:]

    public init() {}

    public static func key(mac: String, session: String) -> String { "\(mac.lowercased())|\(session)" }

    /// The stored list, at launch (once).
    public func load(_ stored: Set<String>) {
        guard let edits = early else { return }
        early = nil
        var merged = stored
        for (key, on) in edits {
            if on { merged.insert(key) } else { merged.remove(key) }
        }
        if keys != merged { keys = merged }
        if !edits.isEmpty { save?(merged) }
    }

    public func isMuted(mac: String, session: String) -> Bool {
        keys.contains(Self.key(mac: mac, session: session))
    }

    public func setMuted(_ on: Bool, mac: String, session: String) {
        let key = Self.key(mac: mac, session: session)
        // Before the stored list loads, the set in memory is not the truth yet: every edit is
        // kept (an unmute of a stored mute included) and applied on top of it in `load`.
        if early != nil {
            early?[key] = on
            if on { keys.insert(key) } else { keys.remove(key) }
            return
        }
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
