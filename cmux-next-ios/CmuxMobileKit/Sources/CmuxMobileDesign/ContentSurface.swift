#if os(iOS)
import CmuxTheme
import SwiftUI
import UIKit

/// The chat's two kinds of surface, from the design system the Mac and the web draw (Leo,
/// 2026-11-22, on a black "1 subagent" card over his themed wallpaper: "WHAT THE FUCK IT'S ALL
/// UNTHEMED ... THEME IT"):
/// - what sits in the page (cards, code blocks, tool output, chips): a content surface level
///   (``ContentSurfaceLevel``, design/chat-surfaces.md): the theme's ink over clear at the level's
///   share, with its line. It shows the Mac's picture through, flips with light and dark, and is
///   never an opaque gray, black or white box.
/// - what floats over the page (toasts, the composer, its bars): glass tinted with the theme's
///   surface at the shared transient veil (``TransientMaterial``, the toast role's veil in
///   schemas/surface-roles/surface-roles.json).
/// The app's views draw these instead of a literal color or an opaque stock surface.
public enum CmuxMobileContentSurface {
    /// The page's ink: the Mac theme's text color while the chat follows the Mac and the theme's
    /// light or dark matches `traits`, else the system label. Resolved each time a trait collection
    /// resolves it, so it follows the theme as it changes.
    public static let ink = UIColor { traits in
        if let palette = CmuxMobileMacTheme.shared.palette, palette.isDark == (traits.userInterfaceStyle == .dark) {
            return palette.label.uiColor
        }
        return UIColor.label.resolvedColor(with: traits)
    }

    /// The fill of `level`: the ink at the level's share.
    public static func fill(_ level: ContentSurfaceLevel) -> UIColor {
        UIColor { ink.resolvedColor(with: $0).withAlphaComponent(inkAlpha($0) * level.fill) }
    }

    /// The 1 px line of `level`: the ink at the level's line share; the ink itself under Increase Contrast.
    public static func line(_ level: ContentSurfaceLevel) -> UIColor {
        UIColor { traits in
            let share = traits.accessibilityContrast == .high && level.line > 0 ? 1 : level.line
            return ink.resolvedColor(with: traits).withAlphaComponent(inkAlpha(traits) * share)
        }
    }

    /// The veil floating glass is tinted with: the theme's surface (the system surface without a
    /// Mac theme) at the transient material's veil.
    public static let floatingVeil = UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        let material = TransientMaterial.standard
        let surface: UIColor
        if let palette = CmuxMobileMacTheme.shared.palette, palette.isDark == dark {
            surface = palette.surface.uiColor
        } else {
            surface = UIColor.cmuxMobileSurface.resolvedColor(with: traits)
        }
        return surface.withAlphaComponent(dark ? material.darkVeilAlpha : material.lightVeilAlpha)
    }

    private static func inkAlpha(_ traits: UITraitCollection) -> CGFloat {
        var alpha: CGFloat = 1
        ink.resolvedColor(with: traits).getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha
    }
}

extension Color {
    /// ``CmuxMobileContentSurface/fill(_:)``. Read in a body, so the view redraws when the Mac's theme changes.
    public static func cmuxMobileContentFill(_ level: ContentSurfaceLevel) -> Color {
        _ = CmuxMobileMacTheme.shared.palette
        return Color(uiColor: CmuxMobileContentSurface.fill(level))
    }

    /// ``CmuxMobileContentSurface/line(_:)``.
    public static func cmuxMobileContentLine(_ level: ContentSurfaceLevel) -> Color {
        _ = CmuxMobileMacTheme.shared.palette
        return Color(uiColor: CmuxMobileContentSurface.line(level))
    }

    /// ``CmuxMobileContentSurface/floatingVeil``.
    public static var cmuxMobileFloatingVeil: Color {
        _ = CmuxMobileMacTheme.shared.palette
        return Color(uiColor: CmuxMobileContentSurface.floatingVeil)
    }
}

extension View {
    /// A content surface in the page (a card, a code block, a chip): the level's ink fill and its
    /// 1 px line, in `shape`.
    public func cmuxMobileContentSurface<S: InsettableShape>(_ level: ContentSurfaceLevel = .card, in shape: S) -> some View {
        modifier(ContentSurfaceModifier(level: level, shape: shape))
    }

    /// Glass that floats over the page (a toast, the composer, a bar over the transcript), tinted
    /// with the theme's surface.
    public func cmuxMobileFloatingGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(FloatingGlassModifier(shape: shape, interactive: interactive))
    }
}

private struct ContentSurfaceModifier<S: InsettableShape>: ViewModifier {
    let level: ContentSurfaceLevel
    let shape: S
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .background(Color.cmuxMobileContentFill(level), in: shape)
            .overlay {
                if level.line > 0 {
                    shape.strokeBorder(Color.cmuxMobileContentLine(level), lineWidth: 1 / max(displayScale, 1))
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct FloatingGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        let glass = Glass.regular.tint(.cmuxMobileFloatingVeil)
        content.glassEffect(interactive ? glass.interactive() : glass, in: shape)
    }
}
#endif
