import AppKit
import Foundation
public import CmuxNextDesign

/// `toast.show` (`cmux.toast({title, message?, tone?})`): a short notice from an app, shown by the
/// app's one toast presenter (`CmuxToastCenter`) in the active window. Each app has one slot: the
/// toast's id is `app:<app id>`, so a new toast from the same app replaces its last, and the
/// presenter's own limits hold (three per window, a closed notice stays quiet for a while). The
/// title is the toast's text and the message its detail (shown when the pointer is on it),
/// followed by the app's id. `tone`
/// is accepted and not drawn yet: the presenter has one look until the unified notice system lands.
/// Local and non-network, so the op needs no scope (`scopes.json` scope `none`).
public nonisolated struct ToastAppOps: AppHostCapabilityHandler {
    /// Shows `toast` in the active window; false when no window can show it.
    let present: @MainActor @Sendable (CmuxToast) -> Bool

    /// - Parameter present: Shows a toast in the active window; false when none can show it.
    public init(present: @escaping @MainActor @Sendable (CmuxToast) -> Bool) {
        self.present = present
    }

    /// Shows toasts in the app's main window (the key window when none is main), through
    /// `CmuxToastCenter`; no window open is a retryable failure.
    public static func inMainWindow() -> ToastAppOps {
        ToastAppOps { toast in
            guard let window = NSApp?.mainWindow ?? NSApp?.keyWindow else { return false }
            CmuxToastCenter.shared.show(toast, in: window)
            return true
        }
    }

    static let maxTitle = 200
    static let maxMessage = 1_000
    static let tones: Set<String> = ["success", "warning", "danger"]

    public var families: Set<String> { ["toast"] }

    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.op == "toast.show" else { throw .unsupported(request.op) }
        let toast = try Self.toast(request)
        guard await present(toast) else {
            throw AppHostCapabilityError(code: "operation.failed", message: "no window is open to show the toast", retryable: true)
        }
        return .null
    }

    /// The toast `request` asks for, or `invalid_params`.
    static func toast(_ request: AppHostCapabilityRequest) throws(AppHostCapabilityError) -> CmuxToast {
        let title = (request.params["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AppHostCapabilityError(code: "invalid_params", message: "toast.show needs a title") }
        guard title.count <= maxTitle else { throw AppHostCapabilityError(code: "invalid_params", message: "a toast title is at most \(maxTitle) characters") }
        let message = request.params["message"]?.stringValue
        if let message, message.count > maxMessage {
            throw AppHostCapabilityError(code: "invalid_params", message: "a toast message is at most \(maxMessage) characters")
        }
        if let tone = request.params["tone"]?.stringValue, !tones.contains(tone) {
            throw AppHostCapabilityError(code: "invalid_params", message: "a toast tone is success, warning or danger")
        }
        // The detail names the app, so an app's notice never passes for one of cmux's own.
        let source = AppsStrings.toastSource(request.app)
        return CmuxToast(id: "app:\(request.app)", message: title, detail: message.map { "\($0)\n\(source)" } ?? source)
    }
}
