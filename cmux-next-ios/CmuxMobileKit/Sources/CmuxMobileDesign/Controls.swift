#if os(iOS)
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// A switch in the `success` green (SPEC 1.2 "Toggle tint", 2.1 `success`).
///
/// The app tints system controls with the neutral `label` color, so the
/// selected tab, menu values and checkmarks read as label and not blue. A
/// `Toggle` takes its on-track color from that same tint, which made every on
/// switch a white track under a white knob in Dark Mode (black in Light). This
/// style pins switches back to green whatever tint surrounds them.
public struct CmuxMobileSwitchToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(theme.colors.success.color)
    }
}

extension ToggleStyle where Self == CmuxMobileSwitchToggleStyle {
    /// A green switch (`CmuxMobileSwitchToggleStyle`).
    public static var cmuxMobileSwitch: CmuxMobileSwitchToggleStyle { CmuxMobileSwitchToggleStyle() }
}

extension View {
    /// The app's neutral control tint (`label`) for a screen or sheet whose
    /// toggles are switches: pickers, links, steppers and checkmarks follow
    /// `label`, switches stay green. Use it in place of a bare
    /// `.tint(label)` on any container that holds a switch `Toggle`. Do not use
    /// it around menus: their toggles are checkmark items and keep the default
    /// style.
    public func cmuxMobileNeutralControlTint() -> some View {
        tint(theme.colors.label.color)
            .toggleStyle(.cmuxMobileSwitch)
    }
}
#endif
