import AppKit
import CmuxNextDesign

extension AppJSON {
    /// A scene color prop as the AppKit renderer draws it: a tone (`primary secondary tertiary accent
    /// separator success warning danger hover selected badge clear`, the names `cmux.theme` hands
    /// scripts) or `#RRGGBB[AA]`; nil for anything else. No blue: `accent` is primary text, the
    /// emphasis cmux chrome uses. Read inside the view's theme scope (`performWithTheme`), as the
    /// SwiftUI renderer's `AppSceneColors.token` resolves the same names.
    @MainActor
    var sceneColor: NSColor? {
        guard let token = stringValue else { return nil }
        if let hex = AppSceneStyle.hexColor(token) { return hex }
        switch token {
        case "primary", "accent", "text.primary": return Palette.textPrimary
        case "secondary", "text.secondary": return Palette.textSecondary
        case "tertiary", "text.tertiary": return Palette.textTertiary
        case "separator": return Palette.separator
        case "success": return Palette.success
        case "warning": return Palette.attention
        case "danger": return Palette.danger
        case "hover": return Palette.hoverFill
        case "selected": return Palette.selectionFill
        case "badge": return Palette.badgeFill
        case "clear": return .clear
        default: return nil
        }
    }
}
