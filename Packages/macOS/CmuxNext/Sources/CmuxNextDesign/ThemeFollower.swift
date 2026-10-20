public import AppKit

/// Tells a view's owner of every color change of the scope the view draws in, shown or hidden
/// (I5, cx-8w027.12). For views that send their theme as data, not pixels: a web page host
/// pushes the tokens to its page, so a page shown after a theme change paints its first frame
/// in the new colors. A theme repaint leaves hidden subtrees until shown (`ThemeRepaint`); this
/// is the one path that reaches them, and a push costs one small message (the host drops a push
/// equal to its last one).
///
/// The view's owner calls ``rebind()`` where its scope can change: on moving to a window or a
/// superview, and in its theme hook (a scope re-rooted above it runs the hook).
public final class ThemeFollower: ThemeResponsive {
    private weak var view: NSView?
    private weak var scope: ThemeScope?
    private let onChange: () -> Void

    public init(_ view: NSView, onChange: @escaping () -> Void) {
        self.view = view
        self.onChange = onChange
    }

    /// Follows the scope `view` draws in now.
    public func rebind() {
        let now = view?.themeScope
        guard now !== scope else { return }
        scope?.removeResponder(self)
        now?.addResponder(self)
        scope = now
    }

    public func themeDidChange() {
        onChange()
    }
}
