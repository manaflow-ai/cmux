import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextSettingsWindow
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import UiShellShootKit

// CmuxNextSettingsWindow's scene host (cmux-ui-settings --shoot DIR): the Density Playground over the same token
// catalog the app's palette row builds (DensityHandlers), on a throwaway DesignSettings that saves nothing. It links
// the Settings window and the modules whose densities it lists, never the app, so the App stays unchanged.

@main
@MainActor
struct UiSettingsHostMain {
    static func main() {
        let entries = DensityTokenCatalog.entries(fallbacks: [
            SidebarRowTuning.densityFallbacks, VerticalTabListMetrics.densityFallbacks, OmnibarMetrics.densityFallbacks])
        let density = DensityPlaygroundWindow(model: DensityPlaygroundModel(entries: entries, design: DesignSettings(),
                                                                            persist: { _, _ in }))
        UiShellShooter.runIfAsked { _ in
            [UiShellScene(name: "density-playground", module: "CmuxNextSettingsWindow") { density.show() }]
        }
        FileHandle.standardError.write(Data("usage: cmux-ui-settings --shoot DIR [--scene a,b]\n".utf8))
        exit(64)
    }
}
