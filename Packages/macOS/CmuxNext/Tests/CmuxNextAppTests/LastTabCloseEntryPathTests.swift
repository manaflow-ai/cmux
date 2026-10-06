import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// LAST-TAB-CLOSES-WORKSPACE on the Mac: every way to close a workspace's
/// only tab (Cmd-W, the tab's x, a middle click on the tab, the palette)
/// sends the one shared tab close (`close-surface`); the daemon closes the
/// emptied workspace in the same change, and the app never sends a close of
/// its own (no client-side destructive inference, OWNERSHIP-PRINCIPLES).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct LastTabCloseEntryPathTests {
    enum Path: CaseIterable {
        case commandW, tabCloseButton, tabMiddleClick, palette
    }

    private static func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                                  _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(15), sourceLocation: sourceLocation, condition)
    }

    @Test(arguments: Path.allCases)
    func closingTheOnlyTabSendsOneTabCloseAndTheWorkspaceGoes(_ path: Path) async throws {
        let daemon = try TopologyDaemon(cascadesLastTab: true, firstTabs: [11])
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
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
        try await Self.waitUntil("the tab shows") { window.content?.panes.values.first?.orderedIDs.count == 1 }
        let pane = try #require(window.content?.panes.values.first)
        let tab = try #require(pane.orderedIDs.first)

        switch path {
        case .commandW:
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
        case .tabCloseButton:
            pane.handle(.close(tab, source: .mouse))
        case .tabMiddleClick:
            pane.handle(.close(tab, source: .middleClick))
        case .palette:
            PaletteSourcesBridge.make(services: services).tabs?.closeTab(id: tab.rawValue)
        }

        try await Self.waitUntil("the workspace closed") { services.daemon.store.workspaces.isEmpty }
        let sent = daemon.commands.names.withLock { $0 }
        #expect(sent.filter { $0 == "close-surface" }.count == 1, "sent: \(sent)")
        #expect(!sent.contains("close-workspace"), "the app closed the workspace itself: \(sent)")
    }
}
