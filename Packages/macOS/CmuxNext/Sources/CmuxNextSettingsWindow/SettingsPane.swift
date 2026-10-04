public import AppKit
public import CmuxNextDesign
import SwiftUI

// Settings and Debug Settings as internal page tabs (the App's
// `InternalPageTabStore`): the same root views as their windows, filling a
// pane. The views paint their own background, so the main window's
// background is never changed.

extension SettingsWindowModel {
    /// The Settings tab title ("Settings", localized).
    public static var paneTitle: String { SettingsWindowStrings.windowTitle }

    /// A Settings view over this model, drawn in `scope` (the theme of the
    /// window that shows the tab).
    public func makePaneView(scope: ThemeScope) -> NSView {
        Self.followTheme(scope)
        return SettingsPaneHostingView(model: self)
    }

    /// Draws every open Settings view in `scope` from now on.
    public static func followTheme(_ scope: ThemeScope) {
        SettingsTheme.shared.follow(scope)
    }
}

extension DebugSettingsModel {
    /// The Debug Settings tab title.
    public static var paneTitle: String { DebugSettingsStrings.windowTitle }

    /// A Debug Settings view over this model, drawn in `scope`.
    public func makePaneView(scope: ThemeScope) -> NSView {
        SettingsTheme.shared.follow(scope)
        let view = NSHostingView(rootView: DebugSettingsRootView(model: self))
        view.setAccessibilityIdentifier("cmux.debugSettings.pane")
        return view
    }
}

/// Escape stops a shortcut recording, or closes the Settings page tab when
/// the page is otherwise idle.
final class SettingsPaneHostingView: NSHostingView<SettingsRootView> {
    private weak var model: SettingsWindowModel?

    init(model: SettingsWindowModel) {
        self.model = model
        super.init(rootView: SettingsRootView(model: model))
        setAccessibilityIdentifier("cmux.settings.pane")
        wantsLayer = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySurfaceFill()
    }

    /// Clear over the window's backdrop, or the user's Settings background
    /// (`appearance.surfaces.settings`); cards stay a tint over it.
    private func applySurfaceFill() {
        layer?.backgroundColor = performWithTheme { Palette.surfaceOverride(.settings)?.cgColor }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @available(*, unavailable)
    required init(rootView: SettingsRootView) { fatalError("init(rootView:) is not supported") }

    override func cancelOperation(_ sender: Any?) {
        guard let model else { return }
        if model.recorder != nil {
            model.cancelRecording()
        } else {
            model.host?.closeSettingsPane()
        }
    }
}
