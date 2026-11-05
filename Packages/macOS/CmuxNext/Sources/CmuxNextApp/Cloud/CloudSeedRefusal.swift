import CmuxNextCloud
import CmuxNextDesign
import AppKit

/// A Cloud chat start whose machine can't clone the folder from its git remote (cmux-tui
/// `link start-chat copy --on-seed-refusal ask` answering `seed_refused`): the person is asked
/// before the whole folder is copied instead, with cmux-tui's reason and what the copy would send.
/// A silent copy of a 12.8 GB folder ran a 16 GB machine's disk out ("Broken pipe").
struct CloudSeedRefusal: Equatable {
    static let code = "seed_refused"
    static let copyButton = "copy"
    static let identifier = "cmux.dialog.cloud.seedRefused"

    /// cmux-tui's words: why the machine can't clone it, and the copy's files and size.
    let message: String
    let machine: String

    /// The refusal in `answer`, or nil for any other answer.
    init?(_ answer: CloudMoveCLI.Answer, machine: String) {
        guard !answer.ok, answer.errorCode == Self.code else { return nil }
        message = answer.error ?? Self.code
        self.machine = machine
    }

    var spec: CmuxDialogSpec {
        CmuxDialogSpec(
            title: String(format: String(localized: "cloud.seedRefused.title", defaultValue: "Copy the folder to %@?", table: "Cloud", bundle: .module), machine),
            lines: [message],
            buttons: [.cancel(), CmuxDialogButton(id: Self.copyButton, title: String(localized: "cloud.seedRefused.copy", defaultValue: "Copy the Folder", table: "Cloud", bundle: .module), role: .default)],
            identifier: Self.identifier)
    }

    /// Whether the person picked Copy; false for Cancel, a dismissal or no window to ask in.
    @MainActor func confirmed(in window: NSWindow?) async -> Bool {
        guard let window else { return false }
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        return answer.button == Self.copyButton && !answer.isDismissal
    }
}
