import AppKit
import CmuxBrowser
import CmuxSettings

/// Find, DevTools and zoom for a panel whose page is not WebKit (Chromium).
///
/// Every function here is reached only through a branch that checks
/// ``BrowserPanel/enginePage`` first, so WebKit panels keep their existing paths.
extension BrowserPanel {
    /// The find bar's engine: Chromium's native find when the page has one, else the find
    /// scripts evaluated in the WebKit page.
    func makeFindService() -> any BrowserFinding {
        if let native = enginePage as? any BrowserPageNativeFinding {
            return native.nativeFind
        }
        return BrowserFindService(evaluator: BrowserFindWebViewEvaluator(panel: self))
    }

    /// The page's in-pane DevTools, for Chromium pages.
    var engineDevTools: (any BrowserPageDevToolsHosting)? {
        enginePage as? any BrowserPageDevToolsHosting
    }

    /// Connects the page's context menu and zoom chip to this panel. Called once the page is hosted.
    func attachEnginePageFeatures() {
        guard let enginePage else { return }
        (enginePage as? any BrowserPageContextMenuCustomizing)?.contextMenuHost = self
        zoomIndicator.update(factor: enginePage.pageZoom)
        configureEngineDevTools()
    }

    /// The DevTools divider follows the pane divider thickness setting, and the dock menu shows
    /// the user's Toggle Developer Tools shortcut on its Close row (design review on #21029).
    func configureEngineDevTools() {
        guard let devTools = engineDevTools else { return }
        let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?.tabs.first { $0.id == workspaceId }
        let thickness = workspace?.bonsplitController.configuration.appearance.dividerThickness
            ?? BrowserDevToolsLayout.defaultLineThickness
        let toggle = KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)
        let shortcut = toggle.menuItemKeyEquivalent.map {
            BrowserDevToolsMenuShortcut(key: $0, modifiers: toggle.modifierFlags)
        }
        devTools.configureDevTools(dividerThickness: thickness, closeShortcut: shortcut)
    }

    // MARK: DevTools

    /// Runs a DevTools command on a Chromium page.
    /// - Returns: `nil` for WebKit pages (the caller takes its inspector path), else whether it ran.
    func performEngineDevTools(_ command: BrowserDevToolsCommand) -> Bool? {
        guard enginePage != nil else { return nil }
        guard let devTools = engineDevTools else { return false }
        // Settings may have changed, and the panel may have joined its workspace since it was made.
        configureEngineDevTools()
        devTools.performDevTools(command)
        return true
    }

    /// Whether a Chromium page's DevTools are open; `nil` for WebKit pages.
    var engineDevToolsVisible: Bool? {
        guard enginePage != nil else { return nil }
        return engineDevTools?.devToolsState.isOpen ?? false
    }

    // MARK: Zoom

    /// Chrome's zoom presets for Chromium pages (design spec §7).
    var engineZoomLadder: BrowserZoomLadder { BrowserZoomLadder() }

    /// The zoom-in factor for a Chromium page, or `nil` for WebKit.
    var engineZoomInFactor: Double? {
        enginePage.map { engineZoomLadder.zoomIn(from: $0.pageZoom) }
    }

    /// The zoom-out factor for a Chromium page, or `nil` for WebKit.
    var engineZoomOutFactor: Double? {
        enginePage.map { engineZoomLadder.zoomOut(from: $0.pageZoom) }
    }

    /// Sets a Chromium page's zoom, clamped to the presets' range.
    /// - Parameter factor: The zoom factor.
    /// - Returns: `nil` for WebKit pages; else whether the zoom changed.
    func applyEnginePageZoom(_ factor: Double) -> Result<Bool, BrowserAutomationViewportError>? {
        guard let enginePage else { return nil }
        let clamped = engineZoomLadder.clamp(factor)
        guard abs(enginePage.pageZoom - clamped) >= 0.0001 else { return .success(false) }
        enginePage.pageZoom = clamped
        zoomIndicator.update(factor: clamped)
        return .success(true)
    }

    /// After a zoom shortcut or menu item on a Chromium page: the zoom popover opens for a moment.
    func noteEngineZoomFromUser() {
        guard enginePage != nil else { return }
        zoomIndicator.defaultFactor = BrowserZoomSettings().current(defaults: .standard)
        zoomIndicator.showAfterShortcut()
    }
}
