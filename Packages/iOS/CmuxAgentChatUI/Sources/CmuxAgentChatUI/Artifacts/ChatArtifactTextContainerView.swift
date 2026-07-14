#if canImport(UIKit)
import UIKit

/// Hosts the TextKit 1 text view beside its independently redrawn line gutter.
@MainActor
final class ChatArtifactTextContainerView: UIView {
    let textView: UITextView
    let gutterView = ChatArtifactLineNumberGutterView()

    private let gutterWidthConstraint: NSLayoutConstraint

    override init(frame: CGRect) {
        textView = UITextView(usingTextLayoutManager: false)
        gutterWidthConstraint = gutterView.widthAnchor.constraint(equalToConstant: 0)
        super.init(frame: frame)

        backgroundColor = .clear
        textView.layoutManager.allowsNonContiguousLayout = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0

        gutterView.textView = textView
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutterView)
        addSubview(textView)
        NSLayoutConstraint.activate([
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidthConstraint,
            textView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gutterView.setNeedsDisplay()
    }

    /// Refreshes the immutable line snapshot and the width needed for its largest number.
    func updateLineNumbers(
        index: ChatArtifactLineIndex,
        isVisible: Bool
    ) {
        gutterView.lineIndex = index
        gutterView.textFontPointSize = textView.font?.pointSize
            ?? UIFont.preferredFont(forTextStyle: .body).pointSize
        gutterView.isHidden = !isVisible
        if isVisible {
            let digitCount = max(2, String(index.lineCount).count)
            let font = UIFont.monospacedDigitSystemFont(
                ofSize: max(9, gutterView.textFontPointSize * 0.78),
                weight: .regular
            )
            let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            gutterWidthConstraint.constant = ceil(digitWidth * CGFloat(digitCount) + 18)
        } else {
            gutterWidthConstraint.constant = 0
        }
        gutterView.setNeedsDisplay()
    }
}
#endif
