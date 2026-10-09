import CmuxNextActions
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// A new chat bound for a new chat dock is made in the focused pane, then
/// moved into the dock. It must never show in that pane's strip on the way,
/// or the strip flashes a tab (Leo's smooth north star).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct NewChatDockFlashTests {
    private static func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        try await waitForCondition(timeout: .seconds(15), sourceLocation: sourceLocation, condition)
    }

    @Test func aTabBoundForTheChatDockNeverShowsInTheStrip() async throws {
        let daemon = try TopologyDaemon()
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.start(makeConnection: { daemon.connection() })
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            services.daemon.shutdownConnection()
            daemon.stop()
        }
        try await Self.waitUntil {
            services.daemon.store.isLoaded && services.daemon.store.workspaces.count == 1
        }
        let window = try #require(services.windows.openWindow(workspaces: [TopologyDaemon.firstKey]))
        try await Self.waitUntil { window.content?.panes.isEmpty == false }
        let pane = try #require(window.content?.panes.values.first)
        try await Self.waitUntil { !pane.pane.tabs.isEmpty }
        let tab = try #require(pane.pane.tabs.first)

        pane.pendingDock.insert(tab.id)
        #expect(!pane.snapshot().items.contains { $0.id.rawValue == tab.id })
        pane.pendingDock.removeAll()
        #expect(pane.snapshot().items.contains { $0.id.rawValue == tab.id })

        // Cursor review (#18223): the store swaps the provisional tab for the
        // created one before the creation reply lands; the created tab is
        // hidden from that first snapshot on.
        let provisional = "provisional:dock-bound"
        pane.pendingDock.insert(provisional)
        services.agentTabs.rekey(provisional, to: tab.id)
        #expect(!pane.snapshot().items.contains { $0.id.rawValue == tab.id }, "the created chat showed in the strip")

        // Another chat reaching its dock leaves this one hidden.
        pane.pendingDock.insert("other-chat")
        pane.dockFinished("other-chat")
        #expect(!pane.snapshot().items.contains { $0.id.rawValue == tab.id }, "another dock showed this chat")
        pane.dockFinished(tab.id)
        #expect(pane.snapshot().items.contains { $0.id.rawValue == tab.id })
    }
}
