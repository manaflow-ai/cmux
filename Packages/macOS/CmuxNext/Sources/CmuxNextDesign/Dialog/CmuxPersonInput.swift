public import AppKit
import Darwin

/// Tells the person's own key or click from automation's (cx-zk9t), for the
/// buttons only the person may press (`CmuxDialogConfirmKind`). An event is
/// not the person's when the app posted it itself (`isAppSynthetic`, set by
/// the app from `SyntheticInput`) or when another process posted it (the
/// CGEvent source process is neither 0, the HID system, nor this app).
/// Accessibility presses never count as the person's
/// (`CmuxDialogButtonView.accessibilityPerformPress`).
@MainActor
public struct CmuxPersonInput {
    /// The one instance the dialog views read; the app sets `isAppSynthetic` at launch.
    public static var shared = CmuxPersonInput()
    /// True for input the app posted into itself (debug socket, tests).
    public var isAppSynthetic: @MainActor (NSEvent) -> Bool

    public init(isAppSynthetic: @escaping @MainActor (NSEvent) -> Bool = { _ in false }) {
        self.isAppSynthetic = isAppSynthetic
    }

    /// Whether `event` is the person's own key or click. No event is never the person.
    public func isPerson(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        if isAppSynthetic(event) { return false }
        if let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID), source != 0, source != Int64(getpid()) {
            return false
        }
        return true
    }
}
