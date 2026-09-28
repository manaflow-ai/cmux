public import SwiftUI

private struct CmuxChromeTypefaceKey: EnvironmentKey {
    // The system font, so a subtree that never opts in draws exactly what it
    // drew before the chrome font setting existed.
    static let defaultValue = CmuxChromeTypeface.system
}

public extension EnvironmentValues {
    /// Typeface ``View/cmuxFont(size:weight:design:monospacedDigit:)`` draws
    /// with in this subtree.
    ///
    /// Opt in per chrome surface with ``View/cmuxChromeTypeface(_:)``. It is
    /// deliberately not injected globally: following the terminal font suits
    /// the sidebar, the tab bar and the panels that sit beside a terminal, and
    /// does not suit settings forms and dialogs.
    var cmuxChromeTypeface: CmuxChromeTypeface {
        get { self[CmuxChromeTypefaceKey.self] }
        set { self[CmuxChromeTypefaceKey.self] = newValue }
    }
}

public extension View {
    /// Draws this subtree's cmux chrome text in `typeface`.
    func cmuxChromeTypeface(_ typeface: CmuxChromeTypeface) -> some View {
        environment(\.cmuxChromeTypeface, typeface)
    }
}
