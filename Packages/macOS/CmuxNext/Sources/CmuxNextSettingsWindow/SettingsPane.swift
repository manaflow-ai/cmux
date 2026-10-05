public import AppKit
public import CmuxNextDesign
import SwiftUI

// Debug Settings as an internal page tab (the App's `InternalPageTabStore`): the same root view as
// its window, filling a pane. The view paints its own background, so the main window's background
// is never changed. Settings itself is the React page (R82).

extension DebugSettingsModel {
    /// The Debug Settings tab title.
    public static var paneTitle: String { DebugSettingsStrings.windowTitle }

    /// Draws every open Debug Settings view in `scope` from now on.
    public static func followTheme(_ scope: ThemeScope) {
        SettingsTheme.shared.follow(scope)
    }

    /// A Debug Settings view over this model, drawn in `scope`.
    public func makePaneView(scope: ThemeScope) -> NSView {
        SettingsTheme.shared.follow(scope)
        let view = NSHostingView(rootView: DebugSettingsRootView(model: self))
        view.setAccessibilityIdentifier("cmux.debugSettings.pane")
        return view
    }
}

/// The Settings tab title ("Settings", localized).
public enum SettingsPaneTitle {
    public static var text: String { SettingsWindowStrings.windowTitle }
}
