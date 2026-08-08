#if canImport(UIKit)
public import SwiftUI
import UIKit

/// The mobile composer's text field, backed by UIKit instead of SwiftUI.
///
/// The composer band rides inside the keyboard dock accessory (a `UIInputView`
/// living in the system keyboard window). A SwiftUI `TextField` hosted there
/// cannot summon the software keyboard: its focus bridge takes first responder
/// but UIKit never begins a keyboard presentation, and with the keyboard
/// already up its focus collapses the whole keyboard. A plain `UITextView`
/// first responder inside an input accessory is the long-standing Messages
/// pattern and drives the keyboard normally, so the field is UIKit and SwiftUI
/// keeps only the binding surface.
public struct MobileComposerTextField: UIViewRepresentable {
    @Binding private var text: String
    @Binding private var isFocused: Bool
    private let placeholder: String
    private let textColor: Color
    private let isLocked: Bool
    private let maxLines: Int
    private let accessibilityIdentifier: String

    /// Creates the composer field.
    ///
    /// - Parameters:
    ///   - text: The draft text, owned by the caller's store.
    ///   - isFocused: Mirrors the UIKit first-responder fact out to SwiftUI
    ///     (and accepts programmatic writes in).
    ///   - placeholder: Localized placeholder drawn while the draft is empty.
    ///   - textColor: The theme's field text color.
    ///   - isLocked: Disables editing (dictation owns the text); locking a
    ///     focused field resigns it, matching the SwiftUI `.disabled` behavior.
    ///   - maxLines: Growth cap before the field scrolls internally.
    ///   - accessibilityIdentifier: Stable AX id for UI tests.
    public init(
        text: Binding<String>,
        isFocused: Binding<Bool>,
        placeholder: String,
        textColor: Color,
        isLocked: Bool,
        maxLines: Int = 14,
        accessibilityIdentifier: String
    ) {
        _text = text
        _isFocused = isFocused
        self.placeholder = placeholder
        self.textColor = textColor
        self.isLocked = isLocked
        self.maxLines = maxLines
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public func makeUIView(context: Context) -> GrowingComposerTextView {
        let view = GrowingComposerTextView()
        view.maxLines = maxLines
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Natural-language input to an agent: keep standard iOS text
        // assistance on, matching the SwiftUI field this replaces. The raw
        // terminal proxy keeps these OFF; only the composer enables them.
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .default
        view.spellCheckingType = .default
        view.keyboardType = .default
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = accessibilityIdentifier
        view.accessibilityLabel = placeholder
        view.delegate = context.coordinator
        view.placeholderLabel.text = placeholder
        return view
    }

    public func updateUIView(_ view: GrowingComposerTextView, context: Context) {
        context.coordinator.isFocused = $isFocused
        context.coordinator.text = $text
        if view.text != text {
            view.text = text
            view.refreshPlaceholderAndGrowth()
        }
        view.textColor = UIColor(textColor)
        view.placeholderLabel.textColor = UIColor(textColor).withAlphaComponent(0.4)
        if view.isEditable == isLocked {
            // Locking a focused field resigns it; the dictation controller
            // depends on that lock-driven focus loss NOT being a user action,
            // which the coordinator's delegate mirror preserves.
            view.isEditable = !isLocked
        }
        // Programmatic focus writes (rare; user taps focus UIKit directly).
        if isFocused, !view.isFirstResponder, view.window != nil, !isLocked {
            view.becomeFirstResponder()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    /// Mirrors UIKit editing and responder facts into the SwiftUI bindings.
    public final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        public func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text ?? ""
            (textView as? GrowingComposerTextView)?.refreshPlaceholderAndGrowth()
        }

        public func textViewDidBeginEditing(_ textView: UITextView) {
            if !isFocused.wrappedValue { isFocused.wrappedValue = true }
        }

        public func textViewDidEndEditing(_ textView: UITextView) {
            if isFocused.wrappedValue { isFocused.wrappedValue = false }
        }
    }
}

/// A self-sizing `UITextView` that grows with its content up to `maxLines`
/// and scrolls internally past the cap. Growth is reported through
/// `intrinsicContentSize` so the hosting SwiftUI layout (and the surface's
/// band re-measure) track every line change.
public final class GrowingComposerTextView: UITextView {
    var maxLines: Int = 14

    /// Placeholder drawn while the text is empty, matching the SwiftUI
    /// `TextField` prompt this field replaces.
    let placeholderLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
        ])
        isScrollEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var text: String! {
        didSet { refreshPlaceholderAndGrowth() }
    }

    private var lineHeight: CGFloat {
        (font ?? .preferredFont(forTextStyle: .body)).lineHeight
    }

    private var maxHeight: CGFloat {
        (lineHeight * CGFloat(maxLines)).rounded(.up)
    }

    public override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width * 0.6
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = max(lineHeight.rounded(.up), min(fitted.height, maxHeight))
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Width settles after the first layout pass; growth depends on it.
        refreshPlaceholderAndGrowth()
    }

    func refreshPlaceholderAndGrowth() {
        placeholderLabel.isHidden = !(text ?? "").isEmpty
        let fitted = sizeThatFits(
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        )
        let shouldScroll = fitted.height > maxHeight + 0.5
        if isScrollEnabled != shouldScroll {
            isScrollEnabled = shouldScroll
        }
        invalidateIntrinsicContentSize()
    }
}
#endif
