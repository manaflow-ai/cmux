public import AppKit
public import CmuxNextDesign

/// The Sidebar States Playground's window (`debug.sidebarStatesPlayground`, Debug menu > Sidebar States Playground,
/// DEV and NIGHTLY; Lawrence msg 19746). ``show(themes:)`` opens ``SidebarStatesPlaygroundView`` in its own window,
/// or raises it when open. The App's action holds one; the window lives as long as it does.
@MainActor public final class SidebarStatesPlaygroundWindow {
    private var window: NSWindow?
    private let design: DesignSettings
    private let sections: @MainActor () -> [SidebarStatesPlaygroundSection]

    /// Creates the window's owner; nothing draws until ``show(themes:)``.
    /// - Parameters:
    ///   - design: The settings the real sidebar views read (`DesignSettings.shared`: the row tokens read it). The
    ///     playground sets each column's density and text size on it while it draws that column, then puts the user's back.
    ///   - sections: Sections other packages draw below the sidebar's own sheets (the App's Home filter), read when the
    ///     window opens; none by default.
    public init(design: DesignSettings, sections: @escaping @MainActor () -> [SidebarStatesPlaygroundSection] = { [] }) {
        self.design = design
        self.sections = sections
    }

    /// Opens the playground window, or brings the open one to the front.
    /// - Parameter themes: The light and dark sheets' themes.
    public func show(themes: SidebarStatesPlaygroundThemes) {
        let window = window ?? SidebarStatesPlaygroundView.makeWindow(renderer: SidebarStatesPlaygroundRenderer(design: design, themes: themes),
                                                                         sections: sections())
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
