public import CmuxNextCloud
public import CmuxNextDesign
public import Foundation

/// One native device-code prompt, dismissed when its broker operation is cancelled.
@MainActor
public final class CloudCodexDevicePrompt {
    private let center: CmuxDialogCenter
    private let open: (URL) -> Void
    private var dialogID: Int?

    /// Injects the dialog host and browser opener; credentials never enter this prompt.
    public init(center: CmuxDialogCenter, open: @escaping (URL) -> Void) {
        self.center = center
        self.open = open
    }

    /// Presents a code until the user confirms, cancels, or the broker cancels its operation.
    public func present(_ prompt: CloudCodexLoginPrompt, in scope: CmuxDialogScope) async -> Bool {
        guard dialogID == nil else { return false }
        // wakeup-allow: each iteration suspends for a user answer; only Open sign-in repeats it, and cancellation dismisses the dialog.
        while !Task.isCancelled {
            let spec = Self.spec(prompt)
            let answer = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: CmuxDialogAnswer(button: "cancel", role: .cancel, isDismissal: true))
                        return
                    }
                    dialogID = center.present(spec, in: scope) { continuation.resume(returning: $0) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.dismiss() }
            }
            dialogID = nil
            guard !Task.isCancelled, !answer.isDismissal else { return false }
            if answer.button == "open" { open(prompt.verificationURL) }
            else { return answer.button == "signedIn" }
        }
        return false
    }

    private func dismiss() {
        if let dialogID { center.dismiss(dialogID) }
    }

    /// Production dialog specification, also available to the native gallery.
    public static func spec(_ prompt: CloudCodexLoginPrompt) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: String(localized: "cloud.codexDevice.title", defaultValue: "Sign in to Codex", table: "Cloud", bundle: .module),
            lines: [
                String(format: String(localized: "cloud.codexDevice.code", defaultValue: "Use Codex sign-in on this Mac. Enter this one-time code: %@", table: "Cloud", bundle: .module), prompt.userCode),
                String(localized: "cloud.codexDevice.scope", defaultValue: "Only short-lived access moves to the VM; the refresh token stays on this Mac. Keep cmux running on this Mac to renew Codex access.", table: "Cloud", bundle: .module),
            ],
            buttons: [
                .cancel(String(localized: "cloud.codexDevice.cancel", defaultValue: "Cancel", table: "Cloud", bundle: .module)),
                CmuxDialogButton(id: "open", title: String(localized: "cloud.codexDevice.open", defaultValue: "Open sign-in", table: "Cloud", bundle: .module), role: .default),
                CmuxDialogButton(id: "signedIn", title: String(localized: "cloud.codexDevice.signedIn", defaultValue: "I signed in", table: "Cloud", bundle: .module), role: .normal),
            ], identifier: "cmux.dialog.cloud.codexDeviceCode")
    }
}
