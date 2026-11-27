import AppKit
import CmuxNextDesign

/// Puts an extension's workspace list (`SidebarListReplacement`) in the built-in list's frame, or
/// gives the frame back to the built-in list. The extension draws only while it is mounted, drawn and
/// not failing; in every other case the built-in list shows, unchanged (DESIGN R5).
@MainActor
final class SidebarListSwap {
    /// The extension's view now in the list's place; nil while the built-in list draws.
    private(set) var shown: NSView?

    /// The view to draw in the list's place, or nil for the built-in list.
    static func drawable(_ content: (any SidebarCustomContent)?) -> NSView? {
        guard let content, content.isReady, content.errorText == nil else { return nil }
        return content.view
    }

    /// Places `content`'s view over `frame` in `host` and hides `native`, or removes it and shows
    /// `native`. Called from the sidebar's layout: compares before it touches AppKit.
    func apply(_ content: (any SidebarCustomContent)?, in host: NSView, frame: NSRect, native: NSView) {
        let next = Self.drawable(content)
        if shown !== next {
            shown?.removeFromSuperview()
            shown = next
        }
        if let next {
            if next.superview !== host { host.addSubview(next, positioned: .above, relativeTo: native) }
            if next.frame != frame { next.frame = frame }
        }
        let hidesNative = next != nil
        if native.isHidden != hidesNative { native.isHidden = hidesNative }
    }
}
