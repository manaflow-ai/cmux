import AppKit
import CmuxHomeCore
import CmuxNextDesign

/// What an empty transcript shows before its first page is read (ui-state-fixes M1): "Loading
/// messages…" while the read is out, and "Couldn't load messages." with Try Again when it failed.
/// Never the empty conversation (a Chief's first-run panel): a Chief with history whose read failed
/// must not look new. Centered in the space between the header and the field; only the button
/// takes clicks.
final class HomeTranscriptLoadStateView: NSView {
    let label = ChromeLabel(wrappingLabelWithString: "")
    let retry = NSButton(title: "", target: nil, action: nil)
    /// Try Again: the host reads the transcript again.
    var onRetry: () -> Void = {}
    /// What it shows now; nil hides it.
    private(set) var state: TranscriptWindow.FirstPage?
    private var accent = NSColor.labelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        label.font = Typography.body
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.isSelectable = false
        addSubview(label)
        retry.isBordered = false
        retry.font = Typography.body
        retry.target = self
        retry.action = #selector(retryClicked)
        retry.isHidden = true
        addSubview(retry)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// Shows the first page's state: `.loading` or `.failed`; nil or `.loaded` hides it.
    func show(_ next: TranscriptWindow.FirstPage?) {
        let shown = next == .loaded ? nil : next
        guard shown != state else { return }
        state = shown
        isHidden = shown == nil
        retry.isHidden = shown != .failed
        switch shown {
        case .loading: label.stringValue = HomeStrings.transcriptLoading
        case .failed: label.stringValue = HomeStrings.transcriptLoadFailed
        case .loaded, nil: label.stringValue = ""
        }
        label.setAccessibilityLabel(label.stringValue)
        applyRetryTitle()
        if shown == .failed {
            NSAccessibility.post(element: label, notification: .announcementRequested,
                                 userInfo: [.announcement: HomeStrings.transcriptLoadFailed])
        }
        needsLayout = true
    }

    /// The theme's colours: the label in the secondary text colour, Try Again in the accent.
    func applyColors(text: NSColor, accent: NSColor) {
        label.textColor = text
        self.accent = accent
        applyRetryTitle()
    }

    private func applyRetryTitle() {
        let title = HomeStrings.transcriptRetry
        retry.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Typography.body, .foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        retry.setAccessibilityLabel(title)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 24
        let width = max(0, bounds.width - 2 * inset)
        label.preferredMaxLayoutWidth = width
        let labelHeight = ceil(label.intrinsicContentSize.height)
        let retrySize = retry.isHidden ? .zero : retry.intrinsicContentSize
        let gap: CGFloat = retry.isHidden ? 0 : 6
        let total = labelHeight + gap + ceil(retrySize.height)
        let top = max(0, (bounds.height - total) / 2)
        label.frame = CGRect(x: inset, y: top, width: width, height: labelHeight)
        if !retry.isHidden {
            let w = min(width, ceil(retrySize.width))
            retry.frame = CGRect(x: (bounds.width - w) / 2, y: label.frame.maxY + gap, width: w, height: ceil(retrySize.height))
        }
    }

    /// Only Try Again takes clicks; the rest passes to the transcript under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === label ? nil : hit
    }

    @objc private func retryClicked() { onRetry() }
}
