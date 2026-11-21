#if os(iOS)
import SwiftUI
import UIKit

/// Read-only text with the system's range selection: handles, an adjustable range, the edit
/// menu's Copy, links and VoiceOver's text rotor (a `UITextView`).
///
/// SwiftUI's `.textSelection(.enabled)` on iOS takes a long press for itself and selects the
/// whole `Text` at once, with no handles, and that press then fights the row's context menu
/// (CMUX-33). Chat text follows ChatGPT on iOS instead: a long press opens the context menu,
/// and its Select Text opens this view, where a range can be selected and copied.
public struct SelectableTextView: UIViewRepresentable {
    public let text: String
    public let textStyle: UIFont.TextStyle
    public let monospaced: Bool
    /// False: sized to its text (in a scroll view or a disclosure); true: scrolls itself (a sheet).
    public let scrolls: Bool
    public let textColor: UIColor
    public let identifier: String

    public init(_ text: String, textStyle: UIFont.TextStyle = .body, monospaced: Bool = false, scrolls: Bool = true,
                textColor: UIColor = .label, identifier: String = "selectText.text") {
        self.text = text
        self.textStyle = textStyle
        self.monospaced = monospaced
        self.scrolls = scrolls
        self.textColor = textColor
        self.identifier = identifier
    }

    public func makeUIView(context: Context) -> UITextView {
        let view = makeTextView()
        if !scrolls {
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return view
    }

    public func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard !scrolls, let width = proposal.width, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitted.height)
    }

    /// The configured text view, for UIKit callers (`ChatSelectText`) and tests.
    public func makeTextView() -> UITextView {
        let view = UITextView()
        view.text = text
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = scrolls
        view.dataDetectorTypes = [.link]
        view.backgroundColor = .clear
        view.textColor = textColor
        let base = UIFont.preferredFont(forTextStyle: textStyle)
        view.font = monospaced
            ? UIFontMetrics(forTextStyle: textStyle).scaledFont(for: .monospacedSystemFont(ofSize: base.pointSize, weight: .regular))
            : base
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        view.accessibilityIdentifier = identifier
        return view
    }
}

public extension SelectableTextView {
    /// The Select Text sheet: this text, at medium and large detents, presented from the key
    /// window's top controller. Not a SwiftUI `.sheet` on the row: a transcript row is lazy, and
    /// a chat that follows new rows would recycle it and close the sheet mid-selection.
    func present() {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return }
        let controller = UIViewController()
        controller.view = makeTextView()
        controller.title = String(localized: "Select text")
        let navigation = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak navigation] _ in
            navigation?.dismiss(animated: true)
        })
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        top.present(navigation, animated: true)
    }
}
#endif
