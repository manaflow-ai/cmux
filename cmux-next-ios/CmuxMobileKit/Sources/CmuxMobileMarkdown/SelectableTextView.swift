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

    public init(_ text: String, textStyle: UIFont.TextStyle = .body, monospaced: Bool = false, scrolls: Bool = true) {
        self.text = text
        self.textStyle = textStyle
        self.monospaced = monospaced
        self.scrolls = scrolls
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
        view.textColor = .label
        let base = UIFont.preferredFont(forTextStyle: textStyle)
        view.font = monospaced
            ? UIFontMetrics(forTextStyle: textStyle).scaledFont(for: .monospacedSystemFont(ofSize: base.pointSize, weight: .regular))
            : base
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        view.accessibilityIdentifier = "selectText.text"
        return view
    }
}

/// The Select Text sheet: the whole text in a `SelectableTextView`, at medium and large detents.
struct SelectTextSheet: View {
    let text: String
    let monospaced: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text, monospaced: monospaced)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

public extension View {
    /// Presents the Select Text sheet for `text` (read when it opens) while `isPresented` is true.
    func selectTextSheet(isPresented: Binding<Bool>, monospaced: Bool = false, text: @escaping () -> String) -> some View {
        sheet(isPresented: isPresented) { SelectTextSheet(text: text(), monospaced: monospaced) }
    }
}
#endif
