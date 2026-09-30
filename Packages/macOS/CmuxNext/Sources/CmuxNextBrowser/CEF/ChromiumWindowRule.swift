/// What the app knows about one of its own windows when it appears, for
/// the last-resort guard against Chromium's own top-level windows.
nonisolated struct ChromiumWindowFacts: Equatable, Sendable {
    /// Created by Chromium's views (`NativeWidgetMacNSWindow` or a subclass).
    var chromium: Bool
    /// A Chromium `Browser` window (`BrowserNativeWidgetWindow`): tab strip,
    /// toolbar, menus.
    var browserWindow: Bool
    /// A child window of another window (pages, DevTools docked over a pane,
    /// bubbles, menus, extension popups).
    var hasParent: Bool
    /// Has a title bar (a window, not a bubble, menu or video overlay).
    var titled: Bool
    var visible: Bool
    /// A DevTools window cmux placed on purpose (undocked DevTools).
    var devTools: Bool
    /// Above normal windows (picture-in-picture video or document windows,
    /// which float over every app on purpose).
    var floating: Bool
}

nonisolated enum ChromiumWindowVerdict: Equatable, Sendable {
    case allow
    /// Hide it at once. A Browser window is only hidden: its tabs move into
    /// a pane and Chromium closes it when it is empty.
    case hide
    /// Hide and close it (Task Manager, feedback, profile picker and other
    /// Chromium dialogs with a title bar).
    case close
}

nonisolated enum ChromiumWindowRule {
    /// Today nothing is checked: Chromium's windows show as they are.
    static func verdict(_ facts: ChromiumWindowFacts) -> ChromiumWindowVerdict {
        .allow
    }
}
