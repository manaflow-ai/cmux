import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocusUI
import Foundation
import Testing

/// Two more ways to close what holds a starting pane (a split the daemon has not answered), found by the
/// review of #41385. A person types in the starting pane, the daemon gives the keys back, and then:
///
/// - the person closes the SCREEN GROUP of that pane on a daemon with no `state-resources-v1`: the app
///   sends `close-screen-group` itself and does not go through `ScreenCommands.close`;
/// - a script runs Close Other Panes for a pane of a workspace that no window shows: the app sends one
///   `close-pane` for each other pane and does not go through a tab close.
///
/// On both paths the keys the closed pane gave back stayed held for the window for 3 s and went to the
/// first terminal that got the focus there. They must reach no terminal: the pane is gone with what was
/// typed in it, and a held line with a Return would run in a terminal the person did not type it in.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StartingPaneOtherClosesTests {
    static let typed = "echo typed-in-the-starting-pane\r"

    @Test func aScreenGroupCloseOnADaemonWithoutStateResourcesDropsTheKeysItsStartingPaneGaveBack() async throws {
        let files = StartingPaneFixture.Files()
        defer { files.remove() }
        try await PinnedPageTests.withApp(bridge: files.bridge) { services, _ in
            let controller = try #require(services.windows.active)
            let content = try #require(controller.workspaceContent)
            let window = try #require(content.layoutView.window)
            let windowID = try #require(services.windows.owner(of: window)?.state.id)
            let workspace = content.workspace
            let coordinator = services.keyRouter.creationInputCoordinator

            // The shown screen joins a screen group, as a person makes one.
            let active = content.layoutModel.activeScreenID?.rawValue
            let screen = try #require(workspace.screens.first { $0.id == active } ?? workspace.screens.first, "the workspace has no screen")
            ScreenGroupCommands.create([screen], in: workspace, name: "group", color: nil, daemon: services.daemon)
            try await PinnedPageTests.until({ screen.group != nil && workspace.screenGroups.contains { $0.id == screen.group } }, within: .seconds(30), report: {
                "waited for the screen's group; saw group \(String(describing: screen.group)), \(workspace.screenGroups.count) groups"
            })
            let group = try #require(workspace.screenGroups.first { $0.id == screen.group })

            let starting = try await StartingPaneFixture.start(services: services, content: content, window: window, files: files)
            try #require(services.daemon.store.screen(containing: starting.standIn.pane.handle) === screen, "the starting pane is not in the grouped screen")
            let ref = ScreenGroupRef(workspace: workspace, group: group, daemon: services.daemon, content: content)
            try #require(ref.members.contains { $0 === screen }, "the group does not hold the screen")

            // The daemon looks like one from before `state-resources-v1`: the group close sends `close-screen-group`.
            services.daemon.store.identity?.capabilities.removeAll { $0 == DaemonCapability.stateResources.rawValue }
            try #require(!services.daemon.supports(DaemonCapability.stateResources.rawValue), "the daemon still says state-resources-v1: this run proves nothing")

            let held = ContinuousClock.now
            coordinator.giveBack(Data(Self.typed.utf8), terminal: starting.terminalID)
            ScreenGroupCommands.close(ref, services: services)
            let waited = ContinuousClock.now - held

            var given = Data()
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "keys typed in the starting pane of the closed screen group went to another terminal: \(String(decoding: given, as: UTF8.self))")
            #expect(waited < .milliseconds(2800), "the check ran \(waited) after the give-back: held keys leave by themselves after 3 s, so this run proves nothing")
            coordinator.giveBack(Data("echo given-back-after-the-close\r".utf8), terminal: starting.terminalID)
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "keys given back after the screen group close went to another terminal: \(String(decoding: given, as: UTF8.self))")
        }
    }

    @Test func closeOtherPanesInAWorkspaceNoWindowShowsDropsTheKeysItsStartingPaneGaveBack() async throws {
        let files = StartingPaneFixture.Files()
        defer { files.remove() }
        try await PinnedPageTests.withApp(bridge: files.bridge) { services, connection in
            let controller = try #require(services.windows.active)
            let content = try #require(controller.workspaceContent)
            let window = try #require(content.layoutView.window)
            let windowID = try #require(services.windows.owner(of: window)?.state.id)
            let first = content.workspace
            let store = services.daemon.store
            let coordinator = services.keyRouter.creationInputCoordinator

            // The workspace the person goes to before the script runs.
            _ = try await connection.state.createWorkspace(name: "next-\(UUID().uuidString.prefix(6).lowercased())",
                                                           ephemeral: false, terminal: true, focus: false)
            try await PinnedPageTests.until({ store.workspaces.count >= 2 }, within: .seconds(30), report: { "\(store.workspaces.count) workspaces" })
            let next = try #require(store.workspaces.first { $0 !== first })
            try #require(controller.workspaceContent === content, "the window left its first workspace")

            let starting = try await StartingPaneFixture.start(services: services, content: content, window: window, files: files)
            let startingPane = starting.standIn.pane
            // The pane that stays: the confirmed terminal pane beside the starting one.
            let kept = try #require(content.panes.values.first { pane in
                pane !== starting.standIn && pane.pane.handle.rawValue < ProvisionalPane.firstHandle
                    && pane.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
            }?.pane, "no confirmed terminal pane beside the starting pane: \(StartingPaneFixture.describe(content, services))")

            // The daemon gives the typed keys back while the pane still shows: they are held for the window.
            let held = ContinuousClock.now
            coordinator.giveBack(Data(Self.typed.utf8), terminal: starting.terminalID)

            // The person goes to the other workspace: no window shows the starting pane any more.
            controller.state.showWorkspace(next.id)
            controller.showWorkspace(requested: controller.state.workspaceID)
            let left = await StartingPaneFixture.eventually(within: .milliseconds(1500)) {
                controller.workspaceContent?.workspace === next && services.paneController(for: startingPane) == nil
            }
            try #require(left, "the window still shows the starting pane's workspace: this run proves nothing")
            try #require(services.cache.existingTerminal(starting.tab.id)?.gate != nil, "the starting pane's view is gone with its workspace: this run proves nothing")

            // Close Other Panes, as the CLI and MCP run it, for the pane that stays.
            let target = ActionTargetRef(kind: .pane, id: kept.resourceID?.rawValue ?? kept.id)
            #expect(services.registry.perform("pane.closeOthers", invocation: ActionInvocation(target: target, origin: .cli)), "Close Other Panes was refused")
            let waited = ContinuousClock.now - held

            var given = Data()
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "keys typed in the starting pane that Close Other Panes closed went to another terminal: \(String(decoding: given, as: UTF8.self))")
            #expect(waited < .milliseconds(2800), "the check ran \(waited) after the give-back: held keys leave by themselves after 3 s, so this run proves nothing")
        }
    }
}
