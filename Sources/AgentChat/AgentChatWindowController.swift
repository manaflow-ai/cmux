import AppKit
import CmuxAgentConversation
import CmuxAgentConversationUI
import SwiftUI

/// Hosts ``AgentChatView`` in a standalone window for the focused panel's agent.
///
/// Builds a live `TailingTranscriptConversationSource` for the resolved
/// transcript, so the window updates as the agent produces new turns, and
/// wires the composer's send closure to the panel's terminal through
/// ``AgentChatTerminalSendRouter``. Re-running ``present(for:sendRouter:)``
/// swaps in a fresh source so the window always reflects the panel the user
/// invoked it from.
@MainActor
final class AgentChatWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AgentChatWindowController()

    /// The hosting controller whose root view is swapped per presentation.
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))

    /// Monotonic presentation counter folded into the view identity so each
    /// View Chat invocation rebuilds the view and re-reads the transcript, even
    /// when the same panel is reopened after its transcript has grown.
    private var presentationGeneration: UInt64 = 0

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
        window.contentViewController = hostingController
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Presents the chat for the given resolution, building a fresh live source.
    ///
    /// - Parameters:
    ///   - resolution: The resolved agent kind, session id, and transcript URL
    ///     for the focused panel.
    ///   - sendRouter: The router delivering composer drafts to the panel's
    ///     terminal, or `nil` to present a read-only transcript.
    func present(
        for resolution: AgentChatTranscriptResolver.Resolution,
        sendRouter: AgentChatTerminalSendRouter? = nil
    ) {
        let source = TailingTranscriptConversationSource(
            agentKind: resolution.agentKind,
            sessionId: resolution.sessionId,
            transcriptURL: resolution.transcriptURL
        )
        let composer = sendRouter.map { router in
            ChatComposerActions(send: { text in router.send(text) })
        }
        // `.id` ties the view's identity to this presentation so every View
        // Chat invocation forces SwiftUI to rebuild `AgentChatView` (and its
        // `@State` model), restarting the tail. The generation makes reopening
        // the same panel re-subscribe, while still discarding a previous
        // panel's source.
        presentationGeneration += 1
        let identity = "\(presentationGeneration)|\(resolution.sessionId)"
        hostingController.rootView = AnyView(
            AgentChatView(source: source, composer: composer).id(identity)
        )
        showWindow()
    }

    /// Brings the window to the front.
    private func showWindow() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}
