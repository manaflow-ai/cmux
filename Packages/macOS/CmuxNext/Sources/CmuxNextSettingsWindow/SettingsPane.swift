public import AppKit
public import CmuxNextDesign
import SwiftUI

/// Settings and Debug Settings as internal page tabs (the App's
/// `InternalPageTabStore`): the same root views as their windows, filling a
/// pane. The views paint their own background, so the main window's
/// background is never changed.
@MainActor
public enum SettingsPane {
    /// The Settings tab title ("Settings", localized).
    public static var title: String { SettingsWindowStrings.windowTitle }
    /// The Debug Settings tab title.
    public static var debugTitle: String { DebugSettingsStrings.windowTitle }

    /// A Settings view over `model`, drawn in `scope` (the theme of the
    /// window that shows the tab).
    public static func makeView(model: SettingsWindowModel, scope: ThemeScope) -> NSView {
        SettingsTheme.shared.follow(scope)
        return SettingsPaneHostingView(model: model)
    }

    /// A Debug Settings view over `model`, drawn in `scope`.
    public static func makeDebugView(model: DebugSettingsModel, scope: ThemeScope) -> NSView {
        SettingsTheme.shared.follow(scope)
        let view = NSHostingView(rootView: DebugSettingsRootView(model: model))
        view.setAccessibilityIdentifier("cmux.debugSettings.pane")
        return view
    }

    /// Draws every open Settings view in `scope` from now on.
    public static func follow(_ scope: ThemeScope) {
        SettingsTheme.shared.follow(scope)
    }
}

/// Escape stops a shortcut recording; it never closes the tab.
final class SettingsPaneHostingView: NSHostingView<SettingsRootView> {
    private weak var model: SettingsWindowModel?

    init(model: SettingsWindowModel) {
        self.model = model
        super.init(rootView: SettingsRootView(model: model))
        setAccessibilityIdentifier("cmux.settings.pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @available(*, unavailable)
    required init(rootView: SettingsRootView) { fatalError("init(rootView:) is not supported") }

    override func cancelOperation(_ sender: Any?) {
        if let model, model.recorder != nil { model.cancelRecording() }
    }
}
