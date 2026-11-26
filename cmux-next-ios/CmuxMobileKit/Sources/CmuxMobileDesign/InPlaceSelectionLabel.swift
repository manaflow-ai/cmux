#if os(iOS)
import SwiftUI
import UIKit

/// A content-sized label whose held word can be selected in place.
public struct InPlaceSelectionLabel: UIViewRepresentable {
    private let makeText: (UITraitCollection) -> NSAttributedString
    private let onSelectionChange: ((Bool) -> Void)?
    private let extraMenu: () -> [UIMenuElement]

    public init(_ text: NSAttributedString, onSelectionChange: ((Bool) -> Void)? = nil,
                extraMenu: @escaping () -> [UIMenuElement] = { [] }) {
        self.makeText = { _ in text }
        self.onSelectionChange = onSelectionChange
        self.extraMenu = extraMenu
    }

    public init(_ text: String, textStyle: UIFont.TextStyle = .body, color: UIColor = .label,
                alignment: NSTextAlignment = .natural, onSelectionChange: ((Bool) -> Void)? = nil,
                extraMenu: @escaping () -> [UIMenuElement] = { [] }) {
        self.makeText = { traits in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
        }
        self.onSelectionChange = onSelectionChange
        self.extraMenu = extraMenu
    }

    public func makeUIView(context: Context) -> Host { Host(frame: .zero) }

    public func updateUIView(_ host: Host, context: Context) {
        let text = makeText(host.traitCollection)
        if host.label.attributedText != text {
            if host.label.attributedText?.string != text.string { host.selection.end() }
            host.label.attributedText = text
        }
        host.selection.onChange = onSelectionChange
        host.selection.extraMenu = { _ in extraMenu() }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView host: Host, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        guard width > 0 else { return .zero }
        let size = host.label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(width, ceil(size.width)), height: ceil(size.height))
    }

    public static func dismantleUIView(_ host: Host, coordinator: Void) {
        host.selection.end()
    }

    public final class Host: UIView {
        fileprivate let label = UILabel()
        fileprivate lazy var selection = InPlaceTextSelection(host: self) { [weak self] in
            self.map { [$0.label] } ?? []
        }

        public override init(frame: CGRect) {
            super.init(frame: frame)
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.frame = bounds
            addSubview(label)
        }

        public override var forFirstBaselineLayout: UIView { label }
        public override var forLastBaselineLayout: UIView { label }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}
#endif
