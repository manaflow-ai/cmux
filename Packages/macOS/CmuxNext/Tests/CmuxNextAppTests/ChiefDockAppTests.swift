import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
import Foundation
import Testing

/// The Chief window dock on the real app and daemon (user 2026-11-05): Open Chief Dock (Cmd-I) docks this window's
/// Home at `home.chiefDock.edge` (left) with the stage on another workspace, and runs again as a focus, never a
/// second dock; a link from the docked Chief moves only the stage.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ChiefDockAppTests {
    @Test func openChiefDockDocksTheRealHomeLeftAndAgainOnlyFocusesIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            try #require(!services.home.dock.isClassic, "the docked Home is the default")
            let window = try #require(services.windows.active)
            services.home.ensureHomeWorkspace(connection)
            try await PasswordManagerRouteTests.until({ services.windowHomes.home(in: window.state.id) != nil }, within: .seconds(60),
                                                       report: { services.home.homeWorkspaceStep })
            let home = try #require(services.windowHomes.home(in: window.state.id))
            let other = try #require(await services.windows.createWorkspace(into: window.state.id))
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == other })

            #expect(services.registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ window.state.docks.edge(of: home.id) == .left }, report: {
                "docks \(window.state.docks.all.map { ($0.edge, $0.workspace) }), shown \(window.state.workspaceID ?? "-")"
            })
            #expect(window.state.workspaceID == home.id, "Cmd-I did not focus the docked Chief")
            #expect(window.state.stageWorkspaceID == other, "the stage did not keep the workspace it showed")
            let chief = try #require(window.content)

            // Again: a focus only, the same dock and view.
            #expect(services.registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)))
            #expect(window.state.docks.all.count == 1 && window.content === chief)

            // A jump elsewhere (as a link from the Chief makes) moves the stage only.
            services.windows.show(workspaceID: other, in: window.state)
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == other })
            #expect(window.state.docks.edge(of: home.id) == .left, "the jump undocked the Chief")
            #expect(window.parked[home.id] === chief, "the jump rebuilt the Chief's content")

            // Undock Chief (cmux#37372): Home leaves the dock, the stage keeps the window; again, it refuses.
            #expect(services.registry.perform("home.undockChief", invocation: ActionInvocation(origin: .user)))
            #expect(!window.state.docks.isDocked(home.id), "Undock Chief left the Chief docked")
            #expect(window.state.workspaceID == other, "Undock Chief moved the stage")
            let again = services.registry.capturingRefusal {
                _ = services.registry.perform("home.undockChief", invocation: ActionInvocation(origin: .user))
            }
            #expect(again == RefusalStrings.chiefNotDocked, "a second Undock Chief: \(again ?? "ran")")
        }
    }

    /// No link clicked in the Chief docks it (cmux#37372): a workspace link and a subagent chip's link from Home's
    /// chat replace Home on the window, and the Chief stays undocked.
    @Test func noLinkClickedInTheChiefDocksIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let window = try #require(services.windows.active)
            services.home.ensureHomeWorkspace(connection)
            try await PasswordManagerRouteTests.until({ services.windowHomes.home(in: window.state.id) != nil }, within: .seconds(60),
                                                       report: { services.home.homeWorkspaceStep })
            let home = try #require(services.windowHomes.home(in: window.state.id))
            let other = try #require(await services.windows.createWorkspace(into: window.state.id))
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == other })
            let resource = try #require(services.machines.allWorkspaces.map(\.0).first { $0.id == other }?.resourceID?.rawValue)
            // Home's chat, in this window (as the Home pane mounts it): its links go through the same onAppLink.
            let chat = HomeHostView(services: services, conversation: "conv_local")
            window.root.addSubview(chat)
            defer { chat.removeFromSuperview() }

            for link in ["cmux://workspace/\(resource)", "cmux://chief/0123abcd/session/s-37372", "cmux://session/s-37372"] {
                services.windows.show(workspaceID: home.id, in: window.state, from: .thisWindow)
                try await PasswordManagerRouteTests.until({ window.state.workspaceID == home.id })
                chat.transcript.onAppLink?(try #require(URL(string: link)))
                if link.contains("workspace/") { try await PasswordManagerRouteTests.until({ window.state.workspaceID == other }) }
                services.windows.show(workspaceID: other, in: window.state)
                try await PasswordManagerRouteTests.until({ window.state.workspaceID == other })
                #expect(!window.state.docks.isDocked(home.id), "\(link) docked the Chief")
                #expect(window.state.docks.isEmpty, "\(link) made a dock: \(window.state.docks.all.map(\.workspace))")
            }
        }
    }
}
