#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// The app's look at launch and at its root (PROTOCOL.md "Appearance"): the
/// app target links the shell, not the design module.
public enum ShellAppearance {
    /// Loads the last stored look (a Mac's theme, or the neutral look)
    /// synchronously, before the first frame: a themed phone never flashes
    /// the neutral look.
    @MainActor public static func loadAtLaunch() {
        CmuxMobileAppearance.shared.loadAtLaunch()
    }
}

extension View {
    /// The window root's appearance: the backdrop under everything, a fixed
    /// theme's scheme, and the trait that re-resolves UIKit colors.
    public func cmuxMobileShellAppearanceRoot() -> some View {
        cmuxMobileAppearanceRoot()
    }
}
#endif
