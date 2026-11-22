public import AppKit
public import CmuxNextDesign
import SwiftUI

/// A small floating window that hand-tunes one surface live (Lawrence 2026-11-12: "we need to build a ui to fix the
/// ui so i can hand tune the values"): ``TuningPanelView`` over the given tunables, beside the app so the surface
/// stays in view while a slider moves. It floats over the app's windows and stays up when cmux is not active.
/// The owner keeps one; ``show()`` opens it or raises the open one.
@MainActor public final class TuningPanelWindow {
    private var window: NSWindow?
    private let model: DebugSettingsModel
    private let title: String
    private let export: TuningPanelExport
    private let activeLook: ActiveLookScope?

    /// Creates the panel's owner; nothing draws until ``show()``.
    /// - Parameters:
    ///   - title: The window's title and the Copy Values header.
    ///   - descriptors: The tunables, in the order the panel lists them.
    ///   - store: Where values live (`TunableStore.shared`, the store the surface reads).
    ///   - export: How Copy Values prints choices.
    ///   - activeLook: The app's ``ActiveLookScope`` for the window's backdrop.
    public init(title: String, descriptors: [TunableDescriptor], store: TunableStore = .shared,
                export: TuningPanelExport = TuningPanelExport(), activeLook: ActiveLookScope?) {
        self.title = title
        self.model = DebugSettingsModel(store: store, descriptors: descriptors)
        self.export = export
        self.activeLook = activeLook
    }

    /// Whether the panel is on screen.
    public var isVisible: Bool { window?.isVisible == true }

    /// Opens the panel, or brings the open one to the front, in `scope`'s theme.
    public func show(scope: ThemeScope = .app) {
        let window = window ?? makeWindow(scope: scope)
        self.window = window
        SettingsTheme.shared.follow(scope)
        scope.adopt(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel.
    public func close() { window?.performClose(nil) }

    private func makeWindow(scope: ThemeScope) -> NSWindow {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 440, height: 300)
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.tuningPanel")
        panel.setFrameAutosaveName("cmux.tuningPanel.\(title)")
        SettingsTheme.shared.follow(scope)
        panel.install(kind: .debugSettings, content: NSHostingView(rootView: TuningPanelView(model: model, title: title, export: export)),
                      scope: scope, activeLook: activeLook)
        if !panel.setFrameUsingName("cmux.tuningPanel.\(title)") { panel.center() }
        return panel
    }
}
