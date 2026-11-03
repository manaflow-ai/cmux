public import AppKit
public import CmuxNextDesign

/// The Sidebar States Playground's window (`debug.sidebarStatesPlayground`, Debug menu > Sidebar States Playground,
/// DEV and NIGHTLY; Lawrence msg 19746). ``show(themes:)`` opens ``SidebarStatesPlaygroundView`` in its own window,
/// or raises it when open. The App's action holds one; the window lives as long as it does.
@MainActor public final class SidebarStatesPlaygroundWindow {
    private var window: NSWindow?
    private let design: DesignSettings

    /// Creates the window's owner; nothing draws until ``show(themes:)``.
    /// - Parameter design: The settings the real sidebar views read (`DesignSettings.shared`: the row tokens read it).
    ///   The playground sets each column's density and text size on it while it draws that column, then puts the
    ///   user's back.
    public init(design: DesignSettings) {
        self.design = design
    }

    /// Opens the playground window, or brings the open one to the front.
    /// - Parameter themes: The light and dark sheets' themes.
    public func show(themes: SidebarStatesPlaygroundThemes) {
        let window = window ?? SidebarStatesPlaygroundView.makeWindow(renderer: SidebarStatesPlaygroundRenderer(design: design, themes: themes))
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
