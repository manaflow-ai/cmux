import AppKit

/// Hosts the `/agent-chat` web surface in a standalone window for the focused
/// panel's agent session.
///
/// P1 entry point: resolves the focused panel to its transcript and shows the
/// normalized conversation rendered by the webviews app, live-tailed by the
/// local agent daemon. Re-running ``present(for:)`` retargets the surface so
/// the window always reflects the panel the user invoked it from.
@MainActor
final class AgentChatWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AgentChatWindowController()

    private let chatViewController = AgentChatWebViewController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.agentChat")
        window.title = String(localized: "agentChat.windowTitle", defaultValue: "Agent Chat")
        window.center()
        window.contentViewController = chatViewController
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Presents the chat surface targeted at the given resolution.
    func present(for resolution: AgentChatTranscriptResolver.Resolution) {
        chatViewController.present(resolution: resolution)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Stops the daemon child when the window closes; the next present spawns
    /// a fresh one.
    func windowWillClose(_ notification: Notification) {
        chatViewController.present(resolution: nil)
    }
}
