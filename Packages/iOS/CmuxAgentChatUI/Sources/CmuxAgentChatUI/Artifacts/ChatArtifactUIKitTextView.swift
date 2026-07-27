#if canImport(UIKit)
import UIKit

/// Reports UIKit/TextKit layout passes without owning artifact scroll state.
@MainActor
final class ChatArtifactUIKitTextView: UITextView {
    var onLayoutDidChange: (() -> Void)?

    override var contentSize: CGSize {
        didSet {
            guard oldValue != contentSize else { return }
            onLayoutDidChange?()
        }
    }

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        super.init(frame: .zero, textContainer: textContainer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutDidChange?()
    }
}
#endif
