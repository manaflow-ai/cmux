public import AppKit
public import CmuxNextDesign
import SwiftUI

/// The Density Overlay Playground (`debug.densityOverlayPlayground`, DEV and NIGHTLY; Lawrence 2026-11-13, density
/// thread): lays a Helium or Chrome capture over cmux's own browser tab bar and omnibar, live, with opacity, a
/// difference blend, an onion-skin flip, a loupe and a pixel-diff count, and opens a ``TuningPanelWindow`` over every
/// density's ``BrowserChromeTuning`` values, so a slider moves the real chrome and the diff updates. Values persist in
/// this build's Debug Settings file; Copy Values exports them.
///
/// The owner keeps one; ``show()`` opens it or raises the open one.
@MainActor public final class DensityOverlayPlaygroundWindow {
    private var window: NSWindow?
    private let model = DensityOverlayModel()
    private let controls: TuningPanelWindow
    private let activeLook: ActiveLookScope?

    /// Creates the playground's owner; nothing draws until ``show()``.
    /// - Parameter activeLook: The app's ``ActiveLookScope`` for the windows' backdrop.
    public init(activeLook: ActiveLookScope? = nil) {
        self.activeLook = activeLook
        controls = TuningPanelWindow(title: TuningPanelStrings.browserChrome, descriptors: BrowserChromeTuning.descriptors,
                                     activeLook: activeLook)
    }

    /// Opens the playground and its Controls panel, or brings them to the front.
    public func show(scope: ThemeScope = .app) {
        let window = window ?? makeWindow(scope: scope)
        self.window = window
        SettingsTheme.shared.follow(scope)
        scope.adopt(window)
        window.makeKeyAndOrderFront(nil)
        controls.show(scope: scope)
    }

    private func makeWindow(scope: ThemeScope) -> NSWindow {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = DensityOverlayStrings.title
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 640, height: 320)
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.densityOverlay")
        panel.setFrameAutosaveName("cmux.densityOverlay")
        SettingsTheme.shared.follow(scope)
        let view = DensityOverlayView(model: model) { [weak self] in self?.controls.show(scope: scope) }
        panel.install(kind: .debugSettings, content: NSHostingView(rootView: view), scope: scope, activeLook: activeLook)
        if !panel.setFrameUsingName("cmux.densityOverlay") { panel.center() }
        return panel
    }
}
