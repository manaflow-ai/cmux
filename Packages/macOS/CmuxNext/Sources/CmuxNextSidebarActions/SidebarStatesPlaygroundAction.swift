public import CmuxNextActions
import CmuxNextDesign
public import CmuxNextDesignTokens
public import CmuxNextSidebar

/// Debug menu > Sidebar States Playground (`debug.sidebarStatesPlayground`, DEV and NIGHTLY; Lawrence msg 19746:
/// "show me all the possible sidebar states, and i will critique their sizings"): opens
/// ``SidebarStatesPlaygroundWindow``, its sheets in the galleries' Soft Blue pair from the theme files the app knows.
@MainActor
public struct SidebarStatesPlaygroundAction {
    public static let id: ActionID = "debug.sidebarStatesPlayground"
    private let themeColors: @MainActor () -> [String: ThemeFileColors]
    private let sections: @MainActor () -> [SidebarStatesPlaygroundSection]

    /// - Parameters:
    ///   - themeColors: Every theme file's colors by name (the app's theme catalog), read when the window opens.
    ///   - sections: Sections other packages draw below the sidebar's own sheets (the App's Home filter), read when the
    ///     window opens; none by default.
    public init(themeColors: @escaping @MainActor () -> [String: ThemeFileColors],
                sections: @escaping @MainActor () -> [SidebarStatesPlaygroundSection] = { [] }) {
        self.themeColors = themeColors
        self.sections = sections
    }

    /// Binds the action: one window per registry, raised when it is already open.
    public func bind(into registry: ActionRegistry) {
        let themeColors = themeColors
        let playground = SidebarStatesPlaygroundWindow(design: .shared, sections: sections)
        registry.bindEffect(Self.id, effect: { _ in
            playground.show(themes: SidebarStatesPlaygroundThemes(colors: themeColors()))
            return .done
        })
    }
}
