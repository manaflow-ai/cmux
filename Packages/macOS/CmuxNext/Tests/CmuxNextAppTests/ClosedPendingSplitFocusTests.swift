import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// STATUS 1584 (found by the P0 1193 owner on feat bcec3ce42ba): Cmd-D, Cmd-W, Cmd-D in ONE main-actor turn made no pane
/// at the second Cmd-D. Cmd-W cancelled the pending split and the store took its stand-in out at once, but the window
/// still showed the stand-in and kept the focus on it until its store observation ran in a later turn, so the second
/// Cmd-D split the closed stand-in, which no daemon pane takes over.
///
/// Not a person's bug: a person's keys each run in their own turn, and the observation runs between them (the base
/// journey close-pending-split-then-split passed in a real key window). It is a same-turn guarantee for any burst that
/// runs in one turn (a batch of scripted actions): a close of a pending split shows in its own turn.
///
/// Every key goes through the app's key path (the key router, then the window, as `CmuxApplication.sendEvent` runs a
/// key), all in one turn. No key is HELD at the checked steps: a test window is never key, so a key the creation hold
/// keeps is replayed through `NSApp.sendEvent` to no window (the test would fail for the rig, not the app; the first red
/// did). The test first proves that the second Cmd-D ran (the key router's record of the keys it runs). Both terminals are new panes made by splits: the test app's
/// first pane is an agent chat, where Cmd-D and Cmd-W mean other things.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClosedPendingSplitFocusTests {
    @Test func cmdDAfterCmdWClosedAPendingSplitMakesANewPaneWithTheFocus() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            let original = try await Self.startingTerminal(services: services, content: content, window: window)
            let before = Set(content.panes.keys)
            // One main-actor turn, no await, from Cmd-D up to the second Cmd-D.
            let firstSplit = try Self.press("d", .command, keyCode: 2, services: services, window: window)
            let first = try #require(content.panes.first { !before.contains($0.key) }?.value,
                                     "the first Cmd-D shows no pane in its turn (held: \(firstSplit)): \(Self.describe(content, services))")
            let firstKey = first.paneKey
            // The focus on the new pane in this turn, as when its focus landed before Cmd-W (the path the P0 1193 owner
            // saw: Cmd-W closes the stand-in's own tab). A person's focus on a pane is a new intent: it ends the wait for
            // the split's tab, so Cmd-W is no close of a creation still on its way. Whether the focus landed by itself in
            // the key's turn depended on timing (the first red took the other path, and its second Cmd-D was held).
            PaneHandlers.focus(first.layoutPaneID, in: content)
            try #require(content.focus.state.pane == firstKey && content.focus.state.expectation == nil,
                         "the test needs the focus on the split's stand-in and no focus wait: \(Self.describe(content, services))")
            _ = try Self.press("w", .command, keyCode: 13, services: services, window: window)
            let afterClose = Self.describe(content, services)
            let secondSplit = try Self.press("d", .command, keyCode: 2, services: services, window: window)
            // A key a hold keeps is replayed to no window in a test, so a held Cmd-D is not a result: it must have RUN as
            // the split (the key router records each key it runs; a held key leaves Cmd-W's record). A hold that only
            // waits for a selected terminal's surface lets a Command chord through while it holds nothing.
            let ran = services.keyRouter.lastInterception
            try #require(ran?.action == "splitRight", // dispatched, not held; whether it made a pane is the check below
                         "the second Cmd-D did not run (held: \(secondSplit), last run \(String(describing: ran))), so it is not a result: \(Self.describe(content, services))")

            // In the same turn: the focus names a pane the store has (never the closed stand-in's id), and the second
            // Cmd-D shows its new pane.
            let focused = content.focus.state.pane
            let live = focused.flatMap { content.paneController(key: $0) }.map { services.daemon.store.pane($0.pane.handle) != nil } ?? false
            #expect(live, "after Cmd-W closed the pending split \(firstKey), the focus names pane \(focused ?? "-"), which the store does not have; after Cmd-W: \(afterClose)")
            let shown = content.panes.values.first { !before.contains($0.layoutPaneID) && $0.paneKey != firstKey }
            #expect(shown != nil, "the second Cmd-D (ran: \(String(describing: ran?.ran))) showed no new pane in its turn: \(Self.describe(content, services))")

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

    /// The same cancel path: Cmd-W on the pending split's stand-in cancels its creation, and the stand-in's tab leaves the
    /// close in that turn. On feat it stayed in it: the close asked the daemon what runs in the stand-in's terminal
    /// (`TabCloseGuard`, the close warning's read, which starts in the close's own turn) and then sent a close for the
    /// stand-in's own surface, which the daemon never made. Both follow from the tab being in the close, so the check is
    /// the read, read in the close's turn (no wait: the read starts there or never).
    @Test func cmdWOnAPendingSplitNeitherAsksNorClosesItsStandIn() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            _ = try await Self.startingTerminal(services: services, content: content, window: window)
            let before = Set(content.panes.keys)

            // One main-actor turn: Cmd-D, then Cmd-W on its stand-in.
            _ = try Self.press("d", .command, keyCode: 2, services: services, window: window)
            let standIn = try #require(content.panes.first { !before.contains($0.key) }?.value,
                                       "Cmd-D shows no pane in its turn: \(Self.describe(content, services))")
            let tab = try #require(standIn.pane.tabs.first, "the stand-in has no tab: \(standIn.pane.tabs)")
            try #require(ProvisionalTab.isProvisional(surface: tab.surface), "the split already confirmed: \(Self.describe(content, services))")
            // The focus on the stand-in, as when its focus landed before Cmd-W: Cmd-W then closes the stand-in's own tab
            // through the strip's close (CloseUndoToasts), the path that kept it in the close. (A focus still on its way
            // takes TabLifecycle's cancel branch, which never reaches that close.)
            PaneHandlers.focus(standIn.layoutPaneID, in: content)
            try #require(content.focus.state.pane == standIn.paneKey && content.focus.state.expectation == nil,
                         "the test needs the focus on the stand-in and no focus wait: \(Self.describe(content, services))")
            _ = try Self.press("w", .command, keyCode: 13, services: services, window: window)
            // The close ran (the stand-in's creation is cancelled), so the check below is about this close.
            try #require(!services.daemon.store.creations.isPending(tab: tab.id), "Cmd-W did not cancel the split: \(Self.describe(content, services))")
            #expect(!TabCloseGuard.asking.contains(tab.id), "the close of the cancelled stand-in still asks what runs in it (tab \(tab.id))")
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
