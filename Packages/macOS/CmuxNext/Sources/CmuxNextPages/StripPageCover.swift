public import AppKit

/// Native chrome that a Chromium page's window covers. A page draws in its own child window above its pane, and only
/// its holes (``PageWebView/chromiumWindowHoles``) leave native views the mouse. Chrome under a page outside its holes
/// still draws where the page is clear (a chat is clear over its tab row) but gets no hover, click or right-click: a
/// tab there shows no close button on hover and its right-click opens the page's menu (Leo, 2026-11-07: "it's not,
/// like, showing the close button for some reason at all ... I tried to right-click and then close it, but I don't
/// see that option"). `debug.pane_chrome` reports it for each pane's tab strip.
extension NSView {
    /// The pieces of this view (window coordinates) that a shown Chromium page of its window covers outside its
    /// holes; empty while hidden or out of a window.
    @MainActor public var chromiumPageCover: [CGRect] {
        guard let window, !isHiddenOrHasHiddenAncestor else { return [] }
        return Self.covered(convert(bounds, to: nil),
                            pages: PageRegistry.shownChromiumPages(in: window).map { ($0.rect, $0.page.chromiumWindowHoles) })
    }

    /// The pieces of `rect` inside a page's `rect` and outside that page's `holes`, every rect in one space.
    public nonisolated static func covered(_ rect: CGRect, pages: [(rect: CGRect, holes: [CGRect])]) -> [CGRect] {
        guard !rect.isEmpty else { return [] }
        return pages.flatMap { page -> [CGRect] in
            let under = rect.intersection(page.rect)
            return under.isNull || under.isEmpty ? [] : subtracting(page.holes, from: under)
        }
    }

    /// `rect` less every hole, as disjoint rects.
    public nonisolated static func subtracting(_ holes: [CGRect], from rect: CGRect) -> [CGRect] {
        var pieces = [rect]
        for hole in holes {
            pieces = pieces.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(hole)
                guard !cut.isNull, !cut.isEmpty else { return [piece] }
                return [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                    CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height),
                ].filter { $0.width > 0.5 && $0.height > 0.5 }
            }
        }
        return pieces
    }
}
