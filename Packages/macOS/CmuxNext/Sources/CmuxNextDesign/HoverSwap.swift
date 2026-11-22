public import AppKit
import ObjectiveC
import QuartzCore

/// The one hover-swap rule for every row, tab and tile with hover actions (Leo 2026-11-22: "the dot shouldnt show up
/// when i hover; the cross should be there instead. liekwise with the other icons"; 2026-11-22 00:23: "in all cases,
/// the hovered buttons should just replace the other ones").
///
/// A view that swaps marks for actions tags its parts once: its hover actions (✕, ⋮, pin) as ``Role/action`` and the
/// marks those actions replace (unread dot, spinner, error mark, counts) as ``Role/mark``. Two rules follow:
///
/// 1. While any action of a swap group draws, no mark of that group draws (``violations(in:)`` checks it on a live
///    view tree, so a test or a gallery capture fails the moment a dot and a ✕ are both on screen).
/// 2. Anything may hide a mark (``hide(_:)``); only the view's layout, which knows whether an action shows, makes a
///    mark visible again. A display pass, a glow, a badge update or a theme change that set a mark back to full
///    opacity is what drew the blue dot under the ✕ in the 2026-11-22 NIGHTLY.
///
/// Marks a person points at (a usage warning with a tooltip, an audio button, a pull request chip that moves beside
/// the actions) are not tagged: they keep their place by design.
@MainActor
public struct HoverSwap {
    public init() {}
    public enum Role: Int {
        /// A hover action: the close ✕, the more ⋮, the pin.
        case action
        /// A status mark an action replaces: unread dot or count, spinner, error mark, task count.
        case mark
    }

    private static var roleKey: UInt8 = 0
    private static var groupKey: UInt8 = 0

    /// Tags `views` with `role` inside the swap group `group` (the row, tab or tile that owns them); nil untags.
    public static func tag(_ views: [NSView?], _ role: Role?, in group: NSView) {
        for case let view? in views {
            objc_setAssociatedObject(view, &roleKey, role.map { NSNumber(value: $0.rawValue) }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        objc_setAssociatedObject(group, &groupKey, true as NSNumber, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    public static func role(of view: NSView) -> Role? {
        (objc_getAssociatedObject(view, &roleKey) as? NSNumber).flatMap { Role(rawValue: $0.intValue) }
    }

    public static func isGroup(_ view: NSView) -> Bool {
        (objc_getAssociatedObject(view, &groupKey) as? NSNumber)?.boolValue == true
    }

    /// Hides `marks` at once (no fade): always safe under the rule. Never use it to show one.
    public static func hide(_ marks: [NSView]) {
        for mark in marks where mark.alphaValue != 0 {
            mark.alphaValue = 0
            mark.layer?.removeAnimation(forKey: "opacity")
        }
    }

    /// The opacity `view` draws with on screen: its own and every ancestor's up to `root`, as the render server has
    /// it (presentation layers, so a fade in flight counts as drawn). 0 when it or an ancestor is hidden.
    public static func drawnAlpha(_ view: NSView, below root: NSView) -> CGFloat {
        var alpha: CGFloat = 1
        var current: NSView? = view
        while let v = current {
            if v.isHidden { return 0 }
            let layerOpacity = v.layer.map { CGFloat(($0.presentation() ?? $0).opacity) } ?? v.alphaValue
            alpha *= min(v.alphaValue, layerOpacity)
            if v === root { break }
            current = v.superview
        }
        return alpha
    }

    private static func drawn(_ view: NSView, below group: NSView) -> Bool {
        !view.isHidden && view.frame.width > 0 && view.frame.height > 0 && drawnAlpha(view, below: group) > 0.01
    }

    /// Every swap group under `root` (or `root` itself) where an action and a mark draw at once, as
    /// "Group: mark beside action" strings; empty when the rule holds.
    public static func violations(in root: NSView) -> [String] {
        var groups: [NSView] = []
        func collectGroups(_ v: NSView) {
            if isGroup(v) { groups.append(v) }
            v.subviews.forEach(collectGroups)
        }
        collectGroups(root)
        var found: [String] = []
        for group in groups {
            var actions: [NSView] = [], marks: [NSView] = []
            func collect(_ v: NSView) {
                switch role(of: v) {
                case .action?: actions.append(v)
                case .mark?: marks.append(v)
                case nil: break
                }
                // A nested group answers for its own parts.
                for sub in v.subviews where !isGroup(sub) { collect(sub) }
            }
            collect(group)
            let shownActions = actions.filter { drawn($0, below: group) }
            guard !shownActions.isEmpty else { continue }
            for mark in marks where drawn(mark, below: group) {
                found.append("\(type(of: group)): \(type(of: mark)) draws beside \(shownActions.map { "\(type(of: $0))" })")
            }
        }
        return found
    }
}
