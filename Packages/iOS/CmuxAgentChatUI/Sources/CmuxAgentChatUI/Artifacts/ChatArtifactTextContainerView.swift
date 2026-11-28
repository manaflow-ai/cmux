#if canImport(UIKit)
import UIKit

/// Hosts the TextKit 1 text view beside its independently redrawn line gutter.
@MainActor
final class ChatArtifactTextContainerView: UIView {
    let textView: UITextView
    let gutterView = ChatArtifactLineNumberGutterView()

    private let gutterWidthConstraint: NSLayoutConstraint
    private var wrapsLines = true

    override init(frame: CGRect) {
        textView = ChatArtifactUIKitTextView()
        gutterWidthConstraint = gutterView.widthAnchor.constraint(equalToConstant: 0)
        super.init(frame: frame)

        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .allowsDirectInteraction]
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
        textView.isAccessibilityElement = false
        textView.accessibilityElementsHidden = true
        gutterView.accessibilityElementsHidden = true

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

    /// Exposes one bounded element so accessibility never enumerates TextKit line fragments.
    func updateAccessibility(
        documentID: String,
        content: ChatArtifactTextAccessibilityContent
    ) {
        accessibilityLabel = URL(fileURLWithPath: documentID).lastPathComponent
        accessibilityValue = content.excerpt
        accessibilityHint = content.isTruncated
            ? String(
                localized: "chat.artifact.accessibility.large_text_truncated",
                defaultValue: "Only the beginning of this large document is exposed to assistive technologies.",
                bundle: .module
            )
            : nil
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if wrapsLines {
            textView.textContainer.size = CGSize(
                width: max(
                    0,
                    textView.bounds.width
                        - textView.textContainerInset.left
                        - textView.textContainerInset.right
                ),
                height: .greatestFiniteMagnitude
            )
        }
        gutterView.setNeedsDisplay()
    }

    /// Switches between viewport-width wrapping and an unbounded horizontal container.
    func updateWordWrap(_ wrapsLines: Bool) {
        guard self.wrapsLines != wrapsLines else { return }
        self.wrapsLines = wrapsLines
        let contentOffset = textView.contentOffset
        textView.textContainer.widthTracksTextView = wrapsLines
        textView.textContainer.lineBreakMode = wrapsLines ? .byWordWrapping : .byClipping
        textView.alwaysBounceHorizontal = !wrapsLines
        textView.showsHorizontalScrollIndicator = !wrapsLines
        if wrapsLines {
            textView.textContainer.size = CGSize(
                width: max(
                    0,
                    textView.bounds.width
                        - textView.textContainerInset.left
                        - textView.textContainerInset.right
                ),
                height: .greatestFiniteMagnitude
            )
            textView.setContentOffset(
                CGPoint(x: -textView.adjustedContentInset.left, y: contentOffset.y),
                animated: false
            )
        } else {
            textView.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.setContentOffset(contentOffset, animated: false)
        }
        textView.layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textView.textStorage.length),
            actualCharacterRange: nil
        )
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
