import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// R92: "Show Ghostty Config Diagnostics" is a palette action that opens
/// Settings > Terminal, where the diagnostics group shows the same list as
/// the socket's `ghostty.diagnostics` and `cmux ghostty diagnostics`.
@MainActor
@Suite(.serialized)
struct GhosttyDiagnosticsActionTests {
    @Test func thePaletteActionOpensSettingsAtTheTerminalSection() async throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "ghostty.showDiagnostics" }, "the catalog has the action")
        #expect(descriptor.surfacePlan.palette.isOffered, "the palette lists it")
        #expect(descriptor.title == "Show Ghostty Config Diagnostics")

        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-ghostty-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = ActionBindingCoverageTests.boundServices()
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        defer { window.teardown() }
        await BrowserTabTests.settle { window.content != nil }
        let content = try #require(window.content)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let paneID = LayoutPaneIDFixture.id(paneModel)
        await BrowserTabTests.settle { content.panes[paneID] != nil }
        if content.panes[paneID] == nil { _ = content.makeContentView(for: paneID) }
        content.layoutModel.focus(paneID)

        #expect(services.registry.perform("ghostty.showDiagnostics", invocation: ActionInvocation()))
        #expect(services.pages.keys(of: .settings).count == 1, "the Settings tab opened")
        #expect(services.settingsWindow.currentRoute == "#/settings/terminal", "at the Terminal section")
    }
}
