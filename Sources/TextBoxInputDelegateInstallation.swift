import AppKit

@MainActor
enum TextBoxInputDelegateInstallation {
    @discardableResult
    static func installIfNeeded(
        _ delegate: any NSTextViewDelegate,
        on textView: NSTextView
    ) -> Bool {
        guard textView.delegate !== delegate else { return false }
        textView.delegate = delegate
        return true
    }
}
