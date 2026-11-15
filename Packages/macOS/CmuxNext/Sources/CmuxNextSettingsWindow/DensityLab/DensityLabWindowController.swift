public import AppKit
public import CmuxNextDesign
import SwiftUI

/// The Density Lab's window (`debug.densityLab`, Cmd-Shift-P > Density Lab, DEV and NIGHTLY): a utility panel that
/// stays above the main window, so the chrome it tunes stays in view. ``show()`` makes the panel the first time and
/// brings it to the front after that; each show reads the app's density again.
@MainActor public final class DensityLabWindowController {
    public let model: DensityLabModel
    private var panel: NSPanel?

    public init(hooks: DensityLabHooks) {
        model = DensityLabModel(hooks: hooks)
    }

    /// Opens the lab, or brings it to the front; the first open captures every density.
    public func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.refresh(captureIfEmpty: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Density Lab"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.densityLab")
        panel.contentView = NSHostingView(rootView: DensityLabView(model: model))
        if !panel.setFrameUsingName("cmux.densityLab") { panel.center() }
        panel.setFrameAutosaveName("cmux.densityLab")
        return panel
    }
}
