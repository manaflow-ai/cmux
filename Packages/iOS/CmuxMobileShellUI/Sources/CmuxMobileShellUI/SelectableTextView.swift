#if os(iOS)
import SwiftUI
import UIKit

/// A read-only `UITextView` wrapper: the native iOS text view is what gives
/// the "View as Text" sheet real long-press selection, drag handles, Select
/// All, and Copy. SwiftUI's `Text` + `.textSelection(.enabled)` only offers
/// whole-blob copy, not range selection, which defeats the point of the sheet.
struct SelectableTextView: UIViewRepresentable {
    /// The plain text to display.
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        // Terminal output is data, not prose: keep iOS from restyling it.
        view.dataDetectorTypes = []
        view.text = text
        view.accessibilityIdentifier = "MobileTerminalTextSheetTextView"
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Guarded so SwiftUI re-renders don't clobber an active selection.
        if uiView.text != text {
            uiView.text = text
        }
    }
}
#endif
