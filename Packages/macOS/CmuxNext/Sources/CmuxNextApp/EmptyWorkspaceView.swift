import AppKit
import CmuxNextDesign

/// The deliberate empty state for a workspace with no panes.
///
/// A workspace may be created by another client without its first terminal,
/// or may be waiting for the user after a prior terminal was closed. When its
/// first terminal failed to start, it says why under the title (cx-tzlqb).
final class EmptyWorkspaceView: NSView {
    var onNew: (() -> Void)?
    /// Why the workspace's first terminal did not start; nil hides the line.
    var failure: String? {
        didSet {
            guard failure != oldValue else { return }
            detailLabel.stringValue = failure.map(EmptyWorkspaceStrings.failed) ?? ""
            detailLabel.isHidden = failure == nil
            needsLayout = true // invalidate: the failure line changed (the guard above); the group centers again.
        }
    }

    private let titleLabel = ChromeLabel(labelWithString: EmptyWorkspaceStrings.title)
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    /// The failure line wraps at most this wide.
    static let detailMaxWidth: CGFloat = 520

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        build()
    }

    nonisolated override var isFlipped: Bool { true }

    /// The title and the failure line's frames: one group centered in `bounds`, the line `spacing`
    /// under the title, each centered and no wider than `bounds` less `inset` on each side.
    struct Frames: Equatable {
        var title: CGRect
        var detail: CGRect?

        /// - Parameters:
        ///   - title: The title's one-line size.
        ///   - detail: The failure line's size at its wrap width; nil while it is hidden.
        init(in bounds: CGRect, title: CGSize, detail: CGSize?, spacing: CGFloat, inset: CGFloat) {
            let room = max(0, bounds.width - 2 * inset)
            let total = title.height + (detail.map { spacing + $0.height } ?? 0)
            let top = bounds.midY - total / 2
            func centered(_ size: CGSize, y: CGFloat) -> CGRect {
                let width = min(size.width, room)
                return CGRect(x: bounds.midX - width / 2, y: y, width: width, height: size.height)
            }
            self.title = centered(title, y: top)
            self.detail = detail.map { centered($0, y: top + title.height + spacing) }
        }
    }

    /// The failure line wraps to the view's width (at most `detailMaxWidth`), so its height fits a
    /// narrow pane.
    override func layout() {
        super.layout()
        let inset = Metrics.space6, wrap = min(Self.detailMaxWidth, max(0, bounds.width - 2 * inset))
        let detail = detailLabel.isHidden ? nil
            : detailLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: wrap, height: .greatestFiniteMagnitude))
        let frames = Frames(in: bounds, title: titleLabel.naturalSize, detail: detail, spacing: Metrics.space3, inset: inset)
        let title = backingAlignedRect(frames.title, options: .alignAllEdgesNearest)
        if titleLabel.frame != title { titleLabel.frame = title }
        if let rect = frames.detail.map({ backingAlignedRect($0, options: .alignAllEdgesNearest) }), detailLabel.frame != rect {
            detailLabel.frame = rect
        }
    }

    convenience init(onNew: (() -> Void)? = nil) {
        self.init(frame: .zero)
        self.onNew = onNew
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    private func build() {
        let title = titleLabel
        title.font = Typography.header
        title.alignment = .center

        let detail = detailLabel
        detail.font = Typography.body
        detail.alignment = .center
        detail.isSelectable = true
        detail.focusRingType = .none
        detail.isHidden = true

        addSubview(title)
        addSubview(detail)
        applyColors()
    }

    // visibility-walk-allow: two label color stores in the theme scope, no layout or text measure; cheaper than a deferral
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// Colors resolve in this view's theme scope (its workspace's theme), and
    /// again when the theme or the window changes.
    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            detailLabel.textColor = Palette.textSecondary
        }
    }

    override func keyDown(with event: NSEvent) {
        if Self.isPlainReturn(event) {
            onNew?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isPlainReturn(event) {
            onNew?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isPlainReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }
}
