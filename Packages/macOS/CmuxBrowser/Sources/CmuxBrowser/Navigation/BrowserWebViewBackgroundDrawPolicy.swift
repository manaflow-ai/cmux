public import CmuxPanes

/// Decides whether the browser web view (and the native/SwiftUI fills layered
/// over it) should paint their own opaque background instead of letting the
/// window root backdrop show through. Mirrors the terminal and markdown panel
/// background decisions.
///
/// Pure policy: every input is a resolved value, and the only collaborator is
/// ``CmuxPanes/PanelAppearance/shouldUseClearContentBackground(opacity:usesGhosttyGlassStyle:usesTransparentWindow:)``,
/// itself a pure compute. Safe to evaluate off any actor.
public struct BrowserWebViewBackgroundDrawPolicy: Sendable {
    public init() {}

    /// Whether the web view should draw its background given the page-state
    /// inputs.
    ///
    /// A page that opts into a transparent background (or the blank page on any
    /// theme) defers to the resolved appearance policy; a real page on an opaque
    /// theme always draws so pages without their own CSS background stay
    /// readable.
    public func drawsWebViewBackground(
        isBlankPage: Bool,
        usesTransparentBackground: Bool = false,
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        if usesTransparentBackground {
            return drawsWebViewBackground(
                opacity: opacity,
                usesGhosttyGlassStyle: usesGhosttyGlassStyle,
                usesTransparentWindow: usesTransparentWindow
            )
        }
        guard isBlankPage else { return true }
        return drawsWebViewBackground(
            opacity: opacity,
            usesGhosttyGlassStyle: usesGhosttyGlassStyle,
            usesTransparentWindow: usesTransparentWindow
        )
    }

    /// Whether the web view should draw its background given only the resolved
    /// appearance inputs. The web view paints opaque exactly when the panel
    /// content background is not drawn clear.
    public func drawsWebViewBackground(
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        !PanelAppearance.shouldUseClearContentBackground(
            opacity: opacity,
            usesGhosttyGlassStyle: usesGhosttyGlassStyle,
            usesTransparentWindow: usesTransparentWindow
        )
    }
}
