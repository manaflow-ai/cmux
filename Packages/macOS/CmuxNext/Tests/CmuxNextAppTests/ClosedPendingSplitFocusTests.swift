import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// P0 candidate (STATUS 1584, found by the P0 1193 owner on feat bcec3ce42ba): Cmd-D, keys, Cmd-W, Cmd-D in one burst
/// made NO pane at the second Cmd-D. Cmd-W closed the pending split (its creation was cancelled and the store took its
/// stand-in out at once), but the window still showed the stand-in and kept the focus on its pane id until its store
/// observation ran in a later turn. So the second Cmd-D split the closed stand-in, which no daemon pane takes over, and
/// nothing came. A close of a pending split puts the focus on a live pane in its own turn (the pane the split was made
/// from), so the next key of the burst acts there.
///
/// Every key goes through the app's key path (the key router, then the window, as `CmuxApplication.sendEvent` runs a
/// key), all in one main-actor turn, so no reply and no store observation can come between them. Both terminals are new
/// panes made by splits: the test app's first pane is an agent chat, where Cmd-D and Cmd-W mean other things.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClosedPendingSplitFocusTests {
    @Test func cmdDAfterCmdWClosedAPendingSplitMakesANewPaneWithTheFocus() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            let original = try await Self.startingTerminal(services: services, content: content, window: window)
            let before = Set(content.panes.keys)
            let nonce = String(UInt32.random(in: 100_000...999_999))

            // One main-actor turn, no await, from Cmd-D up to the second Cmd-D.
            let firstSplit = try Self.press("d", .command, keyCode: 2, services: services, window: window)
            let first = try #require(content.panes.first { !before.contains($0.key) }?.value,
                                     "the first Cmd-D shows no pane in its turn (held: \(firstSplit)): \(Self.describe(content, services))")
            let firstKey = first.paneKey
            for character in "echo c5x\(nonce)" {
                _ = try Self.press(String(character), [], keyCode: 0, services: services, window: window)
            }
            _ = try Self.press("w", .command, keyCode: 13, services: services, window: window)
            let afterClose = Self.describe(content, services)
            let secondSplit = try Self.press("d", .command, keyCode: 2, services: services, window: window)

            // In the same turn: the focus names a pane the store has (never the closed stand-in's id), and the second
            // Cmd-D shows its new pane.
            let focused = content.focus.state.pane
            let live = focused.flatMap { content.paneController(key: $0) }.map { services.daemon.store.pane($0.pane.handle) != nil } ?? false
            #expect(live, "after Cmd-W closed the pending split \(firstKey), the focus names pane \(focused ?? "-"), which the store does not have; after Cmd-W: \(afterClose)")
            let shown = content.panes.values.first { !before.contains($0.layoutPaneID) && $0.paneKey != firstKey }
            #expect(shown != nil, "the second Cmd-D (held: \(secondSplit)) showed no new pane in its turn: \(Self.describe(content, services))")

            // Then the outcome the person sees: a new terminal pane, made by the daemon, with the focus; the closed split
            // stays closed and the starting terminal stays.
            @MainActor func made() -> PaneController? {
                content.panes.values.first { pane in
                    !before.contains(pane.layoutPaneID) && pane.paneKey != firstKey && pane.pane.handle.rawValue < ProvisionalPane.firstHandle
                        && pane.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
                }
            }
            let came = await Self.eventually { made() != nil }
            #expect(came, "the second Cmd-D made no terminal pane: \(Self.describe(content, services))")
            guard let pane = made() else { return }
            let focusedNew = await Self.eventually { content.focus.state.pane == pane.paneKey }
            #expect(focusedNew, "the second Cmd-D's pane \(pane.paneKey) did not get the focus: \(Self.describe(content, services))")
            #expect(!content.panes.values.contains { $0.paneKey == firstKey }, "the split closed by Cmd-W came back: \(Self.describe(content, services))")
            #expect(content.panes.values.contains { $0 === original }, "the starting terminal's pane is gone: \(Self.describe(content, services))")
        }
    }

    /// A terminal pane split from the test app's first pane (an agent chat), confirmed, focused with the keyboard, and the
    /// window's creation hold ended: the burst starts from a terminal, as a person's does.
    private static func startingTerminal(services: AppServices, content: WorkspaceContentController, window: NSWindow) async throws -> PaneController {
        var terminal = ActionInvocation(origin: .user)
        terminal.opensTerminal = true
        let before = Set(content.panes.keys)
        let coordinator = services.keyRouter.creationInputCoordinator
        #expect(services.registry.perform("splitRight", invocation: terminal), "the starting split was refused: \(describe(content, services))")
        @MainActor func made() -> PaneController? {
            content.panes.values.first { pane in
                !before.contains(pane.layoutPaneID) && pane.pane.handle.rawValue < ProvisionalPane.firstHandle
                    && pane.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
            }
        }
        try await PinnedPageTests.until({ made() != nil && !coordinator.isHolding(in: window) }, report: {
            "waited for the starting split's confirmed terminal pane and the end of its hold; saw \(describe(content, services))"
        })
        let pane = try #require(made())
        PaneHandlers.focus(pane.layoutPaneID, in: content)
        try await PinnedPageTests.until({
            content.focus.state.pane == pane.paneKey && (window.firstResponder as? NSView)?.isDescendant(of: pane.view) == true
        }, report: { "waited for the focus and the keyboard on the starting terminal \(pane.paneKey); saw focus \(content.focus.state.resolved), first responder \(String(describing: window.firstResponder))" })
        return pane
    }

    /// A key-down of `window` through the app's key path: the key router first, then the window when the router did not
    /// take it. Returns whether the key router took it (ran it as a shortcut, or held it).
    private static func press(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16, services: AppServices,
                              window: NSWindow) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: keyCode))
        let taken = services.keyRouter.interceptKeyDown(event, in: window)
        if !taken { window.sendEvent(event) }
        return taken
    }

    /// Whether `condition` holds within `timeout`. A timeout is the answer "no" (the outcome the test checks), not an error.
    private static func eventually(within timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    /// What a failed check saw: each shown pane (its key, handle, whether the store has it, its tabs), the focused pane.
    private static func describe(_ content: WorkspaceContentController, _ services: AppServices) -> String {
        let panes = content.panes.values.map { pane in
            "\(pane.paneKey) h\(pane.pane.handle.rawValue)\(services.daemon.store.pane(pane.pane.handle) == nil ? " (not in the store)" : ""): \(pane.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" })"
        }
        return "panes \(panes), focus \(content.focus.state.pane ?? "-") \(content.focus.state.resolved), "
            + "expectation \(String(describing: content.focus.state.expectation?.key))"
    }
}
