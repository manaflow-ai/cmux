import AppKit
import CmuxNextDesign
import SwiftUI

/// Sidebar sizes and fonts, derived only from CmuxNextDesign tokens
/// (`Metrics`, `Typography`). Hierarchy comes from weight and gray level.
enum SidebarStyle {
    static var horizontalInset: CGFloat { Metrics.space3 }
    static var compactInset: CGFloat { Metrics.space2 }
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius }
    /// Leading indent of grouped rows (room for the group color rail).
    static var groupIndent: CGFloat { Metrics.space5 }
    /// Icon frame; the glyph inside uses `Metrics.smallIconSize`.
    static var iconBox: CGFloat { Metrics.smallIconSize + Metrics.space2 }
    /// Color swatch and monogram square inside the icon frame.
    static var swatchSize: CGFloat { Metrics.smallIconSize }
    static var controlSize: CGFloat { Metrics.iconSize + Metrics.space2 }
    static var toolbarButtonSize: CGFloat { Metrics.sidebarHeaderHeight }
    static var indicatorSize: CGFloat { Metrics.smallIconSize - Metrics.space1 }
    static var dotSize: CGFloat { Metrics.space3 }
    static var badgeHeight: CGFloat { Metrics.iconSize }
    static var railWidth: CGFloat { Metrics.space1 }
    static var searchHeight: CGFloat { Metrics.sidebarRowHeight }
    static var footerHeight: CGFloat { Metrics.sidebarRowHeightWithSubtitle - Metrics.space2 }
    static var autoscrollZone: CGFloat { Metrics.sidebarRowHeight }
    static var dragThreshold: CGFloat { Metrics.space2 }
    static var overscan: CGFloat { Metrics.sidebarRowHeightWithSubtitle * 10 }

    static var titleFont: NSFont { Typography.body }
    static var titleUnreadFont: NSFont { Typography.bodyEmphasized }
    static var subtitleFont: NSFont { Typography.caption }
    static var headerFont: NSFont { Typography.header }
    static var badgeFont: NSFont { Typography.shortcut }
    static var glyphConfig: NSImage.SymbolConfiguration { .init(pointSize: Metrics.smallIconSize - Metrics.space1, weight: .regular) }
    static var chevronConfig: NSImage.SymbolConfiguration { .init(pointSize: Metrics.smallIconSize - Metrics.space2, weight: .bold) }

    /// Muted tint for a user color, shared with tab groups (`GroupColor`).
    static func color(_ color: GroupColor) -> NSColor {
        color.swatch
    }

}

/// Spring animations that honor Reduce Motion.
enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Row moves, gap open/close, collapse.
    static let layout = Animation.spring(duration: 0.32, bounce: 0.12)
    /// Selection pill glide.
    static let selection = Animation.spring(duration: 0.26, bounce: 0.08)
    /// Titlebar buttons fading in on hover.
    static let fade = Animation.easeOut(duration: 0.14)
    /// Width changes.
    static let width = Animation.spring(duration: 0.30, bounce: 0)
    /// Lift and drop settle.
    static let settle = Animation.spring(duration: 0.28, bounce: 0.18)

    /// Runs `changes` inside an animation context, or instantly with Reduce
    /// Motion. AppKit calls completion handlers on the main thread.
    static func animate(_ animation: Animation, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0
                changes()
            }, completionHandler: completion.map { done in { @Sendable in MainActor.assumeIsolated { done() } } })
            return
        }
        NSAnimationContext.animate(animation, changes: changes, completion: completion)
    }
}

extension NSView {
    /// Resolves a dynamic color for this view's appearance.
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}
