public import AppKit
public import CmuxNextDesign

/// Persistent first-connect recovery, shared by every SSH entry point. The app supplies
/// the session actions; the dialog center owns window dismissal and themed presentation.
@MainActor public final class SSHConnectRecovery {
    private let center: CmuxDialogCenter
    private let retry: () -> Void
    private let check: () -> Void
    private let copy: (String) -> Void
    private let dismissed: () -> Void
    private var dialog: Int?

    public init(center: CmuxDialogCenter = .shared, retry: @escaping () -> Void,
                check: @escaping () -> Void, copy: @escaping (String) -> Void,
                dismissed: @escaping () -> Void) {
        self.center = center
        self.retry = retry
        self.check = check
        self.copy = copy
        self.dismissed = dismissed
    }

    public var isPresented: Bool { dialog != nil }

    /// Repeated link failures keep the same sheet. Copy preserves it; Retry starts one
    /// attempt; Check hands off to the machine checklist; dismissal ends the observation.
    public func present(_ spec: CmuxDialogSpec, error: String, in window: NSWindow) {
        guard dialog == nil else { return }
        dialog = center.present(spec, in: .window(window)) { [weak self, weak window] answer in
            guard let self, self.dialog != nil else { return }
            self.dialog = nil
            switch answer.button {
            case "retry": self.retry()
            case "copy":
                self.copy(error)
                if let window { self.present(spec, error: error, in: window) }
                else { self.dismissed() }
            case "check":
                self.check()
                self.dismissed()
            default: self.dismissed()
            }
        }
    }

    /// A connected, disconnected or removed session withdraws its sheet without
    /// treating programmatic dismissal as another user action.
    public func stop() {
        if let id = dialog {
            dialog = nil
            center.dismiss(id)
        }
    }

    public static func spec(title: String, detail: String, cancel: String, copy: String,
                            check: String, retry: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: title, lines: [detail],
                       buttons: [.cancel(cancel), CmuxDialogButton(id: "copy", title: copy),
                                 CmuxDialogButton(id: "check", title: check),
                                 CmuxDialogButton(id: "retry", title: retry, role: .default)],
                       identifier: "cmux.dialog.remote.connectFailed")
    }
}
