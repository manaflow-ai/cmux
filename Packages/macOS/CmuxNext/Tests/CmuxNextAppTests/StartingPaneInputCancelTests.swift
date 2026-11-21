import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextFocusUI
import Foundation
import Testing

/// A person types a line in a starting pane (a split the daemon has not answered) and closes it.
/// The daemon holds such keys by the terminal's id and writes them to the new terminal when the
/// creation commits, so the app must tell it to drop them: every way to close the pane sends ONE
/// `cancel-creating-input` for the pane's terminal (cmux-shared-behavior: one path, each entry
/// checked), and the keys the daemon gives back reach no other terminal. A daemon from before
/// `creating-input-cancel-v1` is sent nothing, and the close still goes through.
///
/// The app runs on a same-tree cmux-tui through the proxy of ``StartingPaneFixture``, which holds
/// each `split` and writes down each cancel the app sends.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StartingPaneInputCancelTests {
    /// The capability by its wire name: this suite also compiles on a tree without the app's case for it.
    static let capability = "creating-input-cancel-v1"

    /// The ways to close a starting pane.
    nonisolated enum Way: String, CaseIterable, Sendable {
        case closeTabShortcut, tabCloseButton, closeTabFromTheCLI, closePaneAction, closeWorkspace, closeScreen
    }

    @Test(arguments: Way.allCases)
    func aCloseOfAStartingPaneCancelsTheInputTheDaemonHoldsForIt(way: Way) async throws {
        let files = StartingPaneFixture.Files()
        defer { files.remove() }
        try await PinnedPageTests.withApp(bridge: files.bridge) { services, connection in
            let controller = try #require(services.windows.active)
            let content = try #require(controller.workspaceContent)
            let window = try #require(content.layoutView.window)
            let windowID = try #require(services.windows.owner(of: window)?.state.id)
            let store = services.daemon.store
            let coordinator = services.keyRouter.creationInputCoordinator
            try #require(services.daemon.supports(Self.capability), "the same-tree daemon does not serve \(Self.capability): this run proves nothing")
            if way == .closeWorkspace {
                // The workspace the window shows after the close.
                _ = try await connection.state.createWorkspace(name: "next-\(UUID().uuidString.prefix(6).lowercased())",
                                                               ephemeral: false, terminal: true, focus: false)
                try await PinnedPageTests.until({ store.workspaces.count >= 2 }, within: .seconds(30), report: { "\(store.workspaces.count) workspaces" })
                try #require(controller.workspaceContent === content, "the window left its first workspace")
            }
            let starting = try await StartingPaneFixture.start(services: services, content: content, window: window, files: files)
            try #require(files.cancelled.isEmpty, "a cancel went out before any close: \(files.cancelled)")
            coordinator.giveBack(Data("echo typed-in-the-starting-pane\r".utf8), terminal: starting.terminalID)

            try Self.close(way, starting, services: services, content: content, window: window)

            // ONE cancel for the pane's terminal, and no second one later.
            let sent = await StartingPaneFixture.eventually(within: .seconds(10)) { !files.cancelled.isEmpty }
            #expect(sent, "\(way.rawValue) sent no cancel-creating-input: \(StartingPaneFixture.describe(content, services))")
            try await Task.sleep(for: .milliseconds(700))
            #expect(files.cancelled == [starting.terminalID], "\(way.rawValue) sent the cancels \(files.cancelled), not one for \(starting.terminalID)")

            // The keys it gave back reach no terminal of the window, now or later.
            var given = Data()
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            coordinator.giveBack(Data("echo given-back-after-the-close\r".utf8), terminal: starting.terminalID)
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "\(way.rawValue): keys of the closed pane went to another terminal: \(String(decoding: given, as: UTF8.self))")
        }
    }

    @Test func anOlderDaemonIsSentNoCancelAndTheCloseGoesThrough() async throws {
        let files = StartingPaneFixture.Files(olderDaemon: true)
        defer { files.remove() }
        try await PinnedPageTests.withApp(bridge: files.bridge) { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            let store = services.daemon.store
            try #require(!services.daemon.supports(Self.capability), "the proxy did not take \(Self.capability) out: this run proves nothing")
            let starting = try await StartingPaneFixture.start(services: services, content: content, window: window, files: files)

            try Self.close(.closeTabShortcut, starting, services: services, content: content, window: window)

            #expect(!store.creations.isPending(tab: starting.tab.id), "the close did not cancel the split: \(StartingPaneFixture.describe(content, services))")
            let gone = await StartingPaneFixture.eventually { !content.panes.values.contains { $0.paneKey == starting.standIn.paneKey } }
            #expect(gone, "the close left the starting pane: \(StartingPaneFixture.describe(content, services))")
            try await Task.sleep(for: .seconds(1))
            #expect(files.cancelled.isEmpty, "a daemon without \(Self.capability) was sent \(files.cancelled)")
        }
    }

    /// Closes the starting pane (or what holds it) the given way. The pane has the focus.
    private static func close(_ way: Way, _ starting: StartingPaneFixture, services: AppServices, content: WorkspaceContentController,
                              window: NSWindow) throws {
        let focused = content.focus.state.pane == starting.standIn.paneKey && content.focus.state.expectation == nil
        switch way {
        case .closeTabShortcut:
            try #require(focused, "the test needs the focus on the starting pane: \(StartingPaneFixture.describe(content, services))")
            try StartingPaneFixture.press("w", .command, keyCode: 13, services: services, window: window)
        case .tabCloseButton:
            starting.standIn.handle(.close(StripTabID(starting.tab.id), source: .mouse))
        case .closeTabFromTheCLI:
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: starting.tab.id), origin: .cli)),
                    "Close Tab was refused")
        case .closePaneAction:
            try #require(focused, "the test needs the focus on the starting pane: \(StartingPaneFixture.describe(content, services))")
            #expect(services.registry.perform("closePane", invocation: ActionInvocation(origin: .user)), "Close Pane was refused")
        case .closeWorkspace:
            // As the CLI and MCP run it (nothing to ask).
            #expect(services.registry.perform("closeWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: content.workspace.id), origin: .cli)),
                    "Close Workspace was refused")
        case .closeScreen:
            // The one function every screen close runs (the screen's menu, the bar, the actions, a group's close).
            let screen = try #require(services.daemon.store.screen(containing: starting.standIn.pane.handle), "the starting pane is in no screen")
            ScreenCommands.close([screen], in: content.workspace, daemon: services.daemon, services: services)
        }
    }
}
