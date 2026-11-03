import AppKit
import CmuxNextLayout
import Observation

/// The window the person last prompted the Chief from (#32989): the window whose Home
/// transcript sent the message. A Chief turn's caller is the Home chat (`caller.home_chat`),
/// and the app does not know a turn's session, so this is where that turn is: its
/// `system.identify` names this window's Home, and the workspaces it creates without
/// naming a window open here. Nil until a message is sent, or once its window closed;
/// the turn then falls back to the most recent window, as before.
@Observable
final class ChiefPromptWindow {
    /// The prompting window's id (`WindowState.id`).
    private(set) var id: String?

    /// `window` (the transcript's window, or a sheet over it) sent a message to the Chief.
    func note(_ window: NSWindow?, in windows: WindowManager) {
        guard let window, let controller = windows.owner(of: window) else { return }
        if id != controller.state.id { id = controller.state.id }
    }

    /// The prompting window while it is still open.
    func open(in registry: WindowRegistry) -> String? {
        guard let id, registry.window(id)?.isOpen == true else { return nil }
        return id
    }
}

/// New workspaces the CLI told the app about before creating them (`workspace.expect_window`,
/// #32989): the create's idempotency key, which the daemon echoes as the workspace-added
/// delta's `mutation_id`, names the window it opens in. The claim is made when the delta
/// arrives (`DaemonStore.onResourceWorkspaceAdded`), before membership reconciles it, so the
/// workspace never shows in another window first.
struct ExpectedWorkspaceWindows {
    /// The bound: a create that never came (refused, another session's) leaves its entry,
    /// and the oldest goes first.
    static let limit = 64

    /// Where one announced create opens: `window`, selected there only when `shows`
    /// (`workspace create --focus`); otherwise filed without changing what the window shows.
    struct Expected: Equatable {
        var window: String
        var shows: Bool
    }

    private(set) var entries: [String: Expected] = [:]
    private var order: [String] = []

    mutating func expect(key: String, window: String, shows: Bool) {
        if entries.updateValue(Expected(window: window, shows: shows), forKey: key) == nil { order.append(key) }
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
    }

    /// Where `key`'s create opens, taken: one create, one placement.
    mutating func take(_ key: String) -> Expected? {
        guard let expected = entries.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return expected
    }
}
