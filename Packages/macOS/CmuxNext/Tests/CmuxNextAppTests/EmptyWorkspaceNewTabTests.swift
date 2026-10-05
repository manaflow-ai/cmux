import AppKit
import CmuxNextActions
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// Cmd-T from the keyboard while the active workspace has no pane yet gives
/// that workspace its first terminal without a "No pane is focused." notice:
/// the missing pane is what the repair fixes, not a refusal.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct EmptyWorkspaceNewTabTests {
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(15))
        while !condition(), clock.now < end { try await clock.sleep(for: .milliseconds(20)) } // test-only wait
    }

    @Test func keyboardNewTabOnAnEmptyWorkspaceRepairsItWithoutANotice() async throws {
        let daemon = try TopologyDaemon(emptyWorkspace: true)
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        // Only Cmd-T may create the first terminal here.
        services.emptyWorkspaces.canCreate = { false }
        services.daemon.start(makeConnection: { daemon.connection() })
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            services.daemon.shutdownConnection()
            daemon.stop()
        }
        try await Self.waitUntil { services.daemon.store.isLoaded && services.daemon.store.workspaces.count == 1 }
        let window = try #require(services.windows.openWindow(workspaces: [TopologyDaemon.firstKey]))
        services.windows.didActivate(window)
        services.windows.reconcileMembership()
        try await Self.waitUntil { window.content != nil }
        #expect(window.content?.panes.isEmpty == true)

        var notices: [String] = []
        services.registry.refusalObserver = { reason, quiet in
            if AppActionContext.showsNotice(quiet: quiet, hasCaller: services.registry.refusalHasCaller) { notices.append(reason) }
        }
        // A keyboard run: origin user, no caller capturing the refusal.
        #expect(services.registry.perform("newTab.sameKind", invocation: ActionInvocation(origin: .user)))
        #expect(notices.isEmpty, "notices: \(notices)")
        try await Self.waitUntil { window.content?.panes.isEmpty == false }
        #expect(window.content?.panes.count == 1)
        #expect(daemon.commands.names.withLock { $0 }.contains("create-terminal"))
        #expect(window.state.workspaceID == TopologyDaemon.firstKey)
    }
}
