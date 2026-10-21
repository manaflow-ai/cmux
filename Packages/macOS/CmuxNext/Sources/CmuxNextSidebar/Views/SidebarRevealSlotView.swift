import AppKit

/// A slot that reveals and collapses one trailing mark (a group header's spinner) through
/// `setHoverSlotShown`: the slot fades and collapses its width while the mark inside keeps its
/// size. A mark that starts or stops drawing (`shows`) asks the host to lay out again: the
/// mark's own `superview?.needsLayout` lands on this slot, whose layout passes the change on.
final class SidebarRevealSlotView: NSView {
    let content: NSView
    /// Whether the mark draws anything; read on each slot layout.
    private let shows: () -> Bool
    private var lastShows: Bool?

    init(_ content: NSView, shows: @escaping () -> Bool) {
        self.shows = shows
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        content.frame = bounds
        let now = shows()
        if let lastShows, lastShows != now { superview?.needsLayout = true }
        lastShows = now
    }
}
