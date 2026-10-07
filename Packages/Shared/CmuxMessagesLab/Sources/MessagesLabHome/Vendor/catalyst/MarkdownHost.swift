#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Host-side markdown actions shared by every app: show source, scroll a block,
/// copy buttons, links (shared/MARKDOWN.md). The hosts route events here.
extension MessagesWindowView {
    /// The overlay of the visible cell showing `key`.
    func markdownOverlay(_ key: String) -> MarkdownOverlay? {
        for case let cell as RowCell in collection.visibleCells where cell.spec?.key == key { return cell.markdownOverlay }
        return nil
    }

    /// "Show Markdown Source" / "Show Formatted Text": re-measures the message's parts and
    /// replaces its rows in place. The bubble's top keeps its window position (pinned stays pinned).
    func setMarkdownSource(_ show: Bool, id: ID) {
        guard let m = store.state.message(id) else { return }
        MarkdownStore.shared.setShowsSource(id, show)
        let pinned = collection.contentOffset.y >= pinnedOffset - 0.5
        let oldOffset = collection.contentOffset.y
        var changed = false
        let rows: [RowSpec] = model.rows.filter { !$0.ghost }.map { r in
            guard case var .part(p) = r.spec.kind, p.ref.messageId == id, p.ref.partIndex < m.parts.count,
                  case .text = m.parts[p.ref.partIndex] else { return r.spec }
            let v = MeasureCache.shared.size(m, p.ref.partIndex, width: r.spec.width)
            var s = r.spec
            p.size = v.size; p.text = v.text; p.markdown = v.markdown
            s.kind = .part(p); s.height = v.size.height
            changed = true
            return s
        }
        guard changed else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        model.set(rows, at: clock(), ghosts: false)
        let rebase = layout.rebaseIfNeeded()
        layout.invalidateLayout()
        collection.contentInset.top = -minOffset
        setOffset(pinned ? pinnedOffset : min(max(oldOffset + rebase, minOffset), pinnedOffset))
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        refreshVisibleCells()
        CATransaction.commit()
    }

    /// The markdown row under a window point, with the point in body-local coordinates.
    func markdownHit(_ p: CGPoint) -> (hit: Hit, md: MarkdownLayout, local: CGPoint)? {
        guard let h = hit(p), let md = h.row.markdown else { return nil }
        return (h, md, CGPoint(x: p.x - h.body.minX, y: p.y - h.body.minY))
    }

    /// A click: a copy button's code, or a link URL, or nil (not consumed).
    enum MarkdownClick { case copied(String), link(URL) }
    func markdownClick(_ p: CGPoint) -> MarkdownClick? {
        guard let (h, md, local) = markdownHit(p) else { return nil }
        if let o = markdownOverlay(h.key) {
            o.hover(local)
            if let code = o.copyHit(local) { return .copied(code) }
        }
        if let s = md.link(at: local), let url = URL(string: s) { return .link(url) }
        return nil
    }

    /// Mouse moved (or exited with nil): the copy button follows the hovered code block.
    func markdownHover(_ p: CGPoint?) {
        let target = p.flatMap { markdownHit($0) }
        for case let cell as RowCell in collection.visibleCells {
            guard let o = cell.markdownOverlay else { continue }
            o.hover(target?.hit.key == cell.spec?.key ? target?.local : nil)
        }
    }

    /// A horizontal scroll over a scrollable block: scrolls it. Returns the (key, region)
    /// that took it, or nil (the transcript scrolls).
    func markdownScroll(at p: CGPoint, dx: CGFloat, lock: (String, Int)?) -> (String, Int)? {
        if let (key, region) = lock {
            markdownOverlay(key)?.scroll(region: region, by: dx)
            return lock
        }
        guard let (h, md, local) = markdownHit(p), let r = md.region(at: local), md.regions[r].scrollable,
              let o = markdownOverlay(h.key) else { return nil }
        o.scroll(region: r, by: dx)
        return (h.key, r)
    }
}
