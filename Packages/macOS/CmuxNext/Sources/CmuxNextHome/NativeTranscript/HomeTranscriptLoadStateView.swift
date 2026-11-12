import AppKit
import CmuxHomeCore
import CmuxNextDesign

/// What an empty transcript shows before its first page is read (ui-state-fixes M1): "Loading
/// messages…" while the read is out, and "Couldn't load messages." with Try Again when it failed.
/// Never the empty conversation (a Chief's first-run panel): a Chief with history whose read failed
/// must not look new. Centered in the space between the header and the field; over rows already
/// drawn (the inbox's newest message, drawn before the first page) it sits at the top of that space
/// on a filled chip, in a band of its own (``overRowsBand``) that the host keeps clear of the rows,
/// and leaves them shown. Only the button takes clicks.
final class HomeTranscriptLoadStateView: NSView {
    let label = ChromeLabel(wrappingLabelWithString: "")
    let retry = NSButton(title: "", target: nil, action: nil)
    /// The chip under the label and Try Again over drawn rows: a bubble that scrolls under the band
    /// never shows through the text.
    let chip = NSView()
    /// Try Again: the host reads the transcript again.
    var onRetry: () -> Void = {}
    /// What it shows now; nil hides it.
    private(set) var state: TranscriptWindow.FirstPage?
    /// Rows are drawn under it: it sits at the top, above them, instead of centered.
    private(set) var overRows = false
    private var accent = NSColor.labelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 10
        chip.isHidden = true
        addSubview(chip)
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

    /// Space at each side of the label.
    static let sideInset: CGFloat = 24
    /// Space between the top of this view and the chip over drawn rows, and under the chip.
    static let bandInset: CGFloat = 12
    /// Padding inside the chip around the label and Try Again.
    static let chipPadding = NSSize(width: 14, height: 8)

    /// The height of the band the load state takes at the top over drawn rows (0 when it shows none
    /// or sits centered in an empty transcript): the host keeps the oldest row clear of it
    /// (`rowsTopClearance`), so the label and Try Again never sit on a bubble.
    var overRowsBand: CGFloat {
        guard overRows, state != nil else { return 0 }
        return Self.bandInset + contentHeight + 2 * Self.chipPadding.height + Self.bandInset
    }

    /// The label and Try Again stacked, as ``layout()`` places them at the current width.
    private var contentHeight: CGFloat {
        let retryHeight = retry.isHidden ? 0 : ceil(retry.intrinsicContentSize.height) + 6
        return labelFrameSize(maxWidth: maxLabelWidth).height + retryHeight
    }

    /// The widest the label's frame may be: the view less its side insets (and the chip's padding
    /// over drawn rows).
    private var maxLabelWidth: CGFloat {
        let pad = overRows ? Self.chipPadding : .zero
        return max(0, bounds.width - 2 * Self.sideInset - 2 * pad.width)
    }

    /// The label's frame for its whole text, padding included. Over drawn rows it is as wide as the
    /// text on one line (so the chip hugs it), up to `maxWidth`, where it wraps; centered it takes
    /// `maxWidth`. The height is the text's at that width, every line of it. (`intrinsicContentSize`
    /// is the text's own size without the label's 2 pt side padding: a frame that wide wrapped the
    /// last word onto a second line the frame cut off, so "Loading messages…" read "Loading".)
    func labelFrameSize(maxWidth: CGFloat) -> NSSize {
        let width = overRows ? min(maxWidth, ceil(label.naturalSize.width)) : maxWidth
        return NSSize(width: width, height: ceil(label.size(forWidth: width).height))
    }

    /// Shows the first page's state: `.loading` or `.failed`; nil or `.loaded` hides it. `overRows`
    /// puts it at the top, above messages already drawn, instead of centered in an empty transcript.
    func show(_ next: TranscriptWindow.FirstPage?, overRows: Bool = false) {
        let shown = next == .loaded ? nil : next
        if overRows != self.overRows {
            self.overRows = overRows
            chip.isHidden = state == nil || !overRows
            needsLayout = true
        }
        guard shown != state else { return }
        state = shown
        isHidden = shown == nil
        chip.isHidden = shown == nil || !overRows
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

    /// The theme's colours: the label in the secondary text colour, Try Again in the accent, the
    /// chip over drawn rows in `fill`.
    func applyColors(text: NSColor, accent: NSColor, fill: NSColor) {
        chip.layer?.backgroundColor = fill.cgColor
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
        let pad = overRows ? Self.chipPadding : .zero
        let width = maxLabelWidth
        label.preferredMaxLayoutWidth = 0
        let labelSize = labelFrameSize(maxWidth: width)
        let labelHeight = labelSize.height
        let retrySize = retry.isHidden ? .zero : retry.intrinsicContentSize
        let gap: CGFloat = retry.isHidden ? 0 : 6
        let total = labelHeight + gap + ceil(retrySize.height)
        // Over drawn rows: on its chip, in the band at the top. Otherwise centered.
        let top = overRows ? Self.bandInset + pad.height : max(0, (bounds.height - total) / 2)
        let textWidth = labelSize.width
        let retryWidth = min(width, ceil(retrySize.width))
        let contentWidth = max(textWidth, retryWidth)
        label.frame = CGRect(x: overRows ? ((bounds.width - textWidth) / 2).rounded() : Self.sideInset + pad.width, y: top,
                             width: textWidth, height: labelHeight)
        if !retry.isHidden {
            retry.frame = CGRect(x: ((bounds.width - retryWidth) / 2).rounded(), y: label.frame.maxY + gap,
                                 width: retryWidth, height: ceil(retrySize.height))
        }
        if overRows {
            chip.frame = CGRect(x: ((bounds.width - contentWidth) / 2).rounded() - pad.width, y: Self.bandInset,
                                width: contentWidth + 2 * pad.width, height: total + 2 * pad.height)
        }
    }

    /// Only Try Again takes clicks; the rest passes to the transcript under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === label || hit === chip ? nil : hit
    }

    @objc private func retryClicked() { onRetry() }
}
