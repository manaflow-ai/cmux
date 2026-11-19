public import AppKit

/// The pages in `root`'s shown part that have drawn no frame yet: a new or cold workspace's New Tab page or chat.
/// Shown as they are, they are clear (a New Tab page hides its cover) or their loading cover, not the workspace's
/// content. A page its pane already keeps unseen (its own hold, alpha 0) is not counted: the pane shows what it kept.
@MainActor
public struct UnpaintedPages {
    public let pages: [any PaneFirstPaintGated]

    public init(in root: NSView) {
        var found: [any PaneFirstPaintGated] = []
        // A view not laid out yet (a workspace built in this turn) has no viewport to clip by.
        let clips = !root.bounds.isEmpty
        func visit(_ view: NSView) {
            for child in view.subviews where !child.isHidden && child.alphaValue > 0 {
                guard let page = child as? any PaneFirstPaintGated else {
                    visit(child)
                    continue
                }
                if page.neverPainted, !clips || child.convert(child.bounds, to: root).intersects(root.bounds) { found.append(page) }
            }
        }
        visit(root)
        pages = found
    }

    /// Runs `body` once every page painted its first frame (now with none).
    public func whenPainted(_ body: @escaping () -> Void) {
        var left = pages.count
        guard left > 0 else { return body() }
        for page in pages {
            page.whenFirstPainted {
                left -= 1
                if left == 0 { body() }
            }
        }
    }
}

/// What a workspace's first frame waits for when the window shows it in place of another: its shown pages that never
/// painted (``UnpaintedPages``), and, `resized` (shown again at another size than it was parked at), its chats drawn at
/// the new size (``DrawnPages``). A tab switch in a pane waits for the same pages (``PanePaintHold``).
@MainActor
public struct WorkspaceFirstFrame {
    private let root: NSView

    public init(of root: NSView) {
        self.root = root
    }

    /// Whether the window keeps the outgoing workspace until ``whenReady(_:)`` answers. `prerendered`: the view was laid
    /// out and drawn off screen in the window before it was asked for (Cmd-N's reserved view, its settled design); it
    /// shows at once, in the key's frame.
    public func awaits(resized: Bool, prerendered: Bool = false) -> Bool {
        guard !prerendered else { return false }
        return !UnpaintedPages(in: root).pages.isEmpty || resized && !DrawnPages(in: root).pages.isEmpty
    }

    /// Runs `body` once every unpainted page painted and every drawn one drew at the size it shows at.
    ///
    /// Lays `root` out now only for chats that drew before: they note their new size as they lay out. Pages that never
    /// painted paint after the window's own layout pass (`WindowRootView.show` sized the workspace, which marks it), so
    /// a workspace replaced before that pass (the next of fifty quick Cmd-Ns hands its hold off) is never laid out, and
    /// a burst of presses costs what one does (cmux#44329). It is not marked again here: a hidden view keeps the mark,
    /// and every later pass of the window walked each hidden workspace so marked.
    public func whenReady(_ body: @escaping () -> Void) {
        var left = 2
        let one = {
            left -= 1
            if left == 0 { body() }
        }
        let drawn = DrawnPages(in: root)
        UnpaintedPages(in: root).whenPainted(one)
        drawn.whenRedrawn(one)
        if !drawn.pages.isEmpty { root.layoutSubtreeIfNeeded() }
    }
}
