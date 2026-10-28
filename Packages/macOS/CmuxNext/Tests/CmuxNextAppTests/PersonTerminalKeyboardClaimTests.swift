import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextActions
import CmuxNextFocus
import CmuxNextFocusUI
import Foundation
import Testing

/// Terminal input must never reach an agent, whatever the timing (cmux-ad for Lawrence; dogfood v2.2.3, fleet job
/// 2c9383257301002fab1539d7). A person's new terminal (`newTab`) holds the window's keys until it shows. When it never
/// shows (its create failed, or the window stays on Home), the held keys are deleted, but before this the keys typed after
/// the hold ended went to whatever had the keyboard, Home's Chief message box included. The window's keyboard is that
/// terminal's until the person's next intent there (a click, Escape, a focus move, another of their actions), never the
/// box's by a timeout.
@MainActor @Suite(.serialized)
struct PersonTerminalKeyboardClaimTests {
    /// One workspace, two panes side by side, each with one tab.
    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "claim-ws"), name: "claim", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "claim-ws"), index: 0)])
        return tree
    }

    private static func key(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private struct Harness {
        let services: AppServices
        let controller: WindowController
        let window: NSWindow
        let panes: [String]
    }

    private static func withWindow(_ body: (Harness) async throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["claim-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
        let window = try #require(controller.window)
        let panes = try #require(store.workspaces.first?.screens.first?.panes).map(\.id)
        try #require(panes.count == 2)
        controller.focus.send(.focusPane(panes[0], source: .programmatic))
        try await body(Harness(services: services, controller: controller, window: window, panes: panes))
    }

    /// A person's new terminal whose create failed: the keys typed for it are deleted, and the keys typed after the hold
    /// ended are still kept from the window (the box) and no primary input takes the keyboard by itself, until the
    /// person presses Escape.
    @Test func aPersonsNewTerminalThatNeverShowsKeepsTheWindowsKeysUntilEscape() async throws {
        try await Self.withWindow { h in
            let router = h.services.keyRouter
            let coordinator = router.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(100)
            let ticket = try #require(coordinator.beginWorkspace(in: h.controller), "a person's new terminal opened no key hold")
            let typed = try Self.key("e", keyCode: 14, in: h.window)
            let held = router.interceptKeyDown(typed, in: h.window)
            #expect(held, "the hold did not take a key typed for the terminal")
            coordinator.resolve(ticket, workspace: nil, in: h.window) // the create failed
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: h.window) }, report: { "the hold never ended" })

            // After the hold: no new intent of the person, so the window's keyboard is still the terminal's.
            let claimed = h.window.pendingCreationOwnsKeyboard
            #expect(claimed, "a primary input may take the keyboard after the hold ended")
            let lateKey = try Self.key("c", keyCode: 8, in: h.window)
            let late = router.interceptKeyDown(lateKey, in: h.window)
            #expect(late, "a key typed after the hold ended went on to the window (Home's message box)")
            let enterKey = try Self.key("\r", keyCode: 36, in: h.window)
            let enter = router.interceptKeyDown(enterKey, in: h.window)
            #expect(enter, "Return typed after the hold ended went on to the window (it would send Home's message)")

            // Escape is the person's next intent: the claim ends and keys go where the person puts them again.
            let escapeKey = try Self.key("\u{1b}", keyCode: 53, in: h.window)
            let escape = router.interceptKeyDown(escapeKey, in: h.window)
            #expect(!escape, "Escape did not go on to the window")
            let claimedAfterEscape = h.window.pendingCreationOwnsKeyboard
            #expect(!claimedAfterEscape, "the claim outlived the person's Escape")
            let afterKey = try Self.key("x", keyCode: 7, in: h.window)
            let after = router.interceptKeyDown(afterKey, in: h.window)
            #expect(!after, "a key typed after Escape was still kept from the window")
        }
    }

    /// The person moving focus (here: a pane focus by keyboard) is a new intent: the claim ends there.
    @Test func aPersonsFocusMoveEndsTheClaim() async throws {
        try await Self.withWindow { h in
            let coordinator = h.services.keyRouter.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(100)
            let ticket = try #require(coordinator.beginWorkspace(in: h.controller))
            coordinator.resolve(ticket, workspace: nil, in: h.window)
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: h.window) }, report: { "the hold never ended" })
            let claimed = h.window.pendingCreationOwnsKeyboard
            #expect(claimed, "the claim ended with the hold")
            h.controller.focus.send(.focusPane(h.panes[1], source: .keyboard))
            let claimedAfterMove = h.window.pendingCreationOwnsKeyboard
            #expect(!claimedAfterMove, "the claim outlived the person's focus move")
        }
    }

    /// Automation never ends the person's claim: a script's or the CLI's focus move, or its own intent, in that window
    /// (review: a script focusing a pane bumped the focus generation and gave the Chief's box the keyboard back).
    @Test func automationLeavesThePersonsClaimAlone() async throws {
        try await Self.withWindow { h in
            let coordinator = h.services.keyRouter.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(100)
            let ticket = try #require(coordinator.beginWorkspace(in: h.controller))
            coordinator.resolve(ticket, workspace: nil, in: h.window)
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: h.window) }, report: { "the hold never ended" })
            h.controller.focus.send(.focusPane(h.panes[1], source: .cli))
            _ = h.controller.focus.beginIntent()
            let claimed = h.window.pendingCreationOwnsKeyboard
            #expect(claimed, "a script's focus move ended the person's claim on the keyboard")
        }
    }

    /// Another of the person's actions is their next intent: the claim ends.
    @Test func aPersonsActionEndsTheClaim() async throws {
        try await Self.withWindow { h in
            let coordinator = h.services.keyRouter.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(100)
            let ticket = try #require(coordinator.beginWorkspace(in: h.controller))
            coordinator.resolve(ticket, workspace: nil, in: h.window)
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: h.window) }, report: { "the hold never ended" })
            _ = h.services.registry.perform("toggleSidebar", invocation: ActionInvocation(origin: .user))
            let claimed = h.window.pendingCreationOwnsKeyboard
            #expect(!claimed, "the claim outlived the person's next action")
        }
    }

    /// A script's run whose handler performs `newTab` with a default (user) invocation is still the script's: it opens
    /// no key hold and makes no claim (review: the handler read the handed invocation's origin).
    @Test func aNestedRunOfAScriptIsNotThePersons() async throws {
        try await Self.withWindow { h in
            let request = ActionInvocation(arguments: ["command": .string("/bin/sh"), "name": .string("nested")], origin: .user)
            let script = ActionRunScope(origin: .script, allowsViewChange: true)
            _ = ActionRunScope.carrying(script) { h.services.registry.perform("newTab", invocation: request) }
            let holding = h.services.keyRouter.creationInputCoordinator.isHolding(in: h.window)
            let claimed = h.window.pendingCreationOwnsKeyboard
            #expect(!holding, "a script's nested newTab held the person's keys")
            #expect(!claimed, "a script's nested newTab claimed the person's keyboard")
        }
    }

    /// A run that is not a new press: the later turn of an earlier user run (its task keeps the user scope) performs an
    /// action. It is no new intent of the person's, so the claim stays (fourth review: willRunObservers ended it).
    @Test func aNestedUserRunIsNoNewIntent() async throws {
        try await Self.withWindow { h in
            let coordinator = h.services.keyRouter.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(100)
            let ticket = try #require(coordinator.beginWorkspace(in: h.controller))
            coordinator.resolve(ticket, workspace: nil, in: h.window)
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: h.window) }, report: { "the hold never ended" })
            let earlier = ActionRunScope(origin: .user, allowsViewChange: true)
            _ = ActionRunScope.carrying(earlier) { h.services.registry.perform("toggleSidebar", invocation: ActionInvocation(origin: .user)) }
            let claimed = h.window.pendingCreationOwnsKeyboard
            #expect(claimed, "a nested run of an earlier user run ended the person's claim")
        }
    }

    /// The window already shows the workspace when its create replies: the claim ends at that reply, not at a later key
    /// (fourth review: otherwise it could hold again if the window went back without the person).
    @Test func aClaimEndsWhenItsWorkspaceIsShownAtTheReply() async throws {
        try await Self.withWindow { h in
            let coordinator = h.services.keyRouter.creationInputCoordinator
            let ticket = try #require(coordinator.beginWorkspace(in: h.controller))
            let shown = try #require(h.controller.focus.currentState().topology.workspace, "the window shows no workspace")
            coordinator.resolve(ticket, workspace: shown, in: h.window)
            let recorded = coordinator.hasClaim(in: h.window)
            #expect(!recorded, "the claim outlived the reply that named the workspace the window shows")
        }
    }

    /// Only the create that made a claim names its workspace: the first of two quick presses replying does not touch the
    /// second press's claim (coverage of a4c01b0b403's ticket check).
    @Test func anEarlierCreatesReplyLeavesALaterClaimAlone() async throws {
        try await Self.withWindow { h in
            let coordinator = h.services.keyRouter.creationInputCoordinator
            let first = try #require(coordinator.beginWorkspace(in: h.controller))
            _ = try #require(coordinator.beginWorkspace(in: h.controller))
            let shown = try #require(h.controller.focus.currentState().topology.workspace)
            coordinator.resolve(first, workspace: shown, in: h.window)
            let claimed = h.window.pendingCreationOwnsKeyboard
            #expect(claimed, "the first create's reply ended the second press's claim")
        }
    }
}
