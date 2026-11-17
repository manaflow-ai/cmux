public import AppKit
public import CmuxNextDesign
import SwiftUI

/// The Density Playground window (Command Palette "Density Playground"): ``DensityPlaygroundView`` over one
/// ``DensityPlaygroundModel``, a floating panel beside the app so the sidebar and tabs stay in view while a slider
/// moves. The owner keeps one; ``show()`` opens it or raises the open one. Closing it writes any pending change.
@MainActor public final class DensityPlaygroundWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// The playground's state (tests drive it without a window).
    public let model: DensityPlaygroundModel
    private let activeLook: ActiveLookScope?

    /// - Parameters:
    ///   - model: The playground's state.
    ///   - activeLook: The app's ``ActiveLookScope`` for the window's backdrop.
    public init(model: DensityPlaygroundModel, activeLook: ActiveLookScope? = nil) {
        self.model = model
        self.activeLook = activeLook
    }

    /// Whether the window is on screen.
    public var isVisible: Bool { window?.isVisible == true }

    /// Opens the window, or brings the open one to the front, in `scope`'s theme.
    public func show(scope: ThemeScope = .app) {
        model.refresh()
        let window = window ?? makeWindow(scope: scope)
        self.window = window
        SettingsTheme.shared.follow(scope)
        scope.adopt(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window.
    public func close() { window?.performClose(nil) }

    public func windowWillClose(_ notification: Notification) { model.flush() }

    private func makeWindow(scope: ThemeScope) -> NSWindow {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = DensityPlaygroundStrings.title
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 560, height: 360)
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.densityPlayground")
        panel.delegate = self
        SettingsTheme.shared.follow(scope)
        panel.install(kind: .debugSettings, content: NSHostingView(rootView: DensityPlaygroundView(model: model)),
                      scope: scope, activeLook: activeLook)
        if !panel.setFrameUsingName("cmux.densityPlayground") {
            // Beside the app's window, so the chrome being tuned stays in view.
            if let main = NSApp.mainWindow ?? NSApp.keyWindow, let screen = main.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                let x = min(main.frame.maxX + 8, visible.maxX - panel.frame.width)
                panel.setFrameTopLeftPoint(NSPoint(x: max(visible.minX, x), y: main.frame.maxY))
            } else {
                panel.center()
            }
        }
        panel.setFrameAutosaveName("cmux.densityPlayground")
        return panel
    }
}
