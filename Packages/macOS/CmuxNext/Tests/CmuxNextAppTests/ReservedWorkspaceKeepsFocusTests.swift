import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The next Cmd-N's workspace view is built while the person types (STATUS 15250): its build and its hidden window
/// entry (the New Tab page included, maybe the Cmd-T spare) must never take the keyboard or the window's focus. With a
/// focused terminal as first responder, the whole refill runs; the first responder and the focused pane stay, and a
/// line typed through the app's key path reaches that terminal.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ReservedWorkspaceKeepsFocusTests {
    @Test func theRefillKeepsTheFocusedTerminalsKeyboard() async throws {
        try await PinnedPageTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-reserved-keeps-focus")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let controller = try #require(services.windows.active, "no window")
            let content = try #require(controller.workspaceContent)
            let window = try #require(content.layoutView.window)
            let terminal = try await Self.focusedTerminal(services: services, content: content, window: window)
            let surface = try #require(terminal.selectedTab?.surface)
            let responder = try #require(window.firstResponder)
            let pane = content.focus.state.pane

            controller.reservedContent.fill()
            try await PinnedPageTests.until({ controller.reservedContent.ready != nil }, within: .seconds(20),
                                            report: { "the window built no next Cmd-N view" })
            // A page in the hidden view may ask for the keyboard once it loads (its composer's own focus()). WebKit sends
            // that ask as the window's makeFirstResponder on the page's view, outside an input event: send the same ask
            // for each page now, so the window's refusal is checked whenever the page would ask (no load wait).
            let reserved = try #require(controller.reservedContent.ready)
            let pages = Self.descendants(of: reserved.contentView).compactMap { $0 as? AgentPaneView }
            #expect(!pages.isEmpty, "the reserved view holds no page, so no page's ask was checked")
            for page in pages {
                #expect(!window.makeFirstResponder(page.focusTarget), "the window gave the reserved view's hidden page the keyboard")
            }
            #expect(window.firstResponder === responder,
                    "the reserved workspace's refill took the keyboard: \(String(describing: window.firstResponder)), was \(responder)")
            #expect(content.focus.state.pane == pane, "the refill moved the window's focus to \(content.focus.state.pane ?? "-")")
            #expect(services.windows.active?.workspaceContent === content, "the refill showed another workspace")

            let router = services.keyRouter
            for character in "echo kept\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
            func ran(_ text: String) -> Bool {
                text.contains("echo kept") && text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "kept" }
            }
            var screen = ""
            let deadline = ContinuousClock.now + .seconds(15)
            while !ran(screen), ContinuousClock.now < deadline {
                screen = (try? await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(2)).text) ?? screen
                if !ran(screen) { try await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(ran(screen), "the focused terminal did not get the typed line after the refill; its screen: \(screen.debugDescription)")
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    /// A new terminal pane (a split, as a person's Ctrl-D), focused with the keyboard in it.
    private static func focusedTerminal(services: AppServices, content: WorkspaceContentController, window: NSWindow) async throws -> PaneController {
        var invocation = ActionInvocation(origin: .user)
        invocation.opensTerminal = true
        let before = Set(content.panes.keys)
        #expect(services.registry.perform("splitRight", invocation: invocation), "the split was refused")
        @MainActor func made() -> PaneController? {
            content.panes.values.first { pane in
                !before.contains(pane.layoutPaneID) && pane.pane.handle.rawValue < ProvisionalPane.firstHandle
                    && pane.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
            }
        }
        let holds = services.keyRouter.creationInputCoordinator
        try await PinnedPageTests.until({ made() != nil && !holds.isHolding(in: window) }, report: { "no confirmed terminal pane" })
        let pane = try #require(made())
        PaneHandlers.focus(pane.layoutPaneID, in: content)
        try await PinnedPageTests.until({
            content.focus.state.pane == pane.paneKey && (window.firstResponder as? NSView)?.isDescendant(of: pane.view) == true
        }, report: { "the keyboard is not in the terminal: \(String(describing: window.firstResponder))" })
        return pane
    }
}
