import CmuxNextCloud
import CmuxNextDesign
import AppKit

/// A Cloud chat start whose machine can't clone the folder from its git remote (cmux-tui
/// `link start-chat copy --on-seed-refusal ask` answering `seed_refused`): the person is asked
/// before the whole folder is copied instead, with cmux-tui's reason and what the copy would send.
/// A silent copy of a 12.8 GB folder ran a 16 GB machine's disk out ("Broken pipe").
public nonisolated struct CloudSeedRefusal: Equatable, Sendable {
    public static let code = "seed_refused"
    public static let copyButton = "copy"
    public static let identifier = "cmux.dialog.cloud.seedRefused"

    /// cmux-tui's words: why the machine can't clone it, and the copy's files and size.
    public let message: String
    public let machine: String

    /// The refusal in `answer`, or nil for any other answer.
    public init?(_ answer: CloudMoveCLI.Answer, machine: String) {
        guard !answer.ok, answer.errorCode == Self.code else { return nil }
        message = answer.error ?? Self.code
        self.machine = machine
    }

    public var spec: CmuxDialogSpec {
        CmuxDialogSpec(
            title: String(format: String(localized: "cloud.seedRefused.title", defaultValue: "Copy the folder to %@?", table: "Cloud", bundle: .module), machine),
            lines: [message],
            buttons: [.cancel(), CmuxDialogButton(id: Self.copyButton, title: String(localized: "cloud.seedRefused.copy", defaultValue: "Copy the Folder", table: "Cloud", bundle: .module), role: .default)],
            identifier: Self.identifier)
    }

    /// `copy` asking first (`.ask`); a refused seed asks the person in `window` and copies only on their
    /// Copy (`.copy`). Their Cancel, a dismissal or no window throws `declined(reason)`.
    @MainActor public static func copying<Copied>(machine: String, in window: @MainActor () -> NSWindow?, declined: (String) -> any Error,
                                                  _ copy: (CloudMoveCLI.SeedRefusal) async throws -> (CloudMoveCLI.Answer, Copied)) async throws -> (CloudMoveCLI.Answer, Copied) {
        let first = try await copy(.ask)
        guard let refused = CloudSeedRefusal(first.0, machine: machine) else { return first }
        guard await refused.confirmed(in: window()) else { throw declined(refused.message) }
        return try await copy(.copy)
    }

    /// Whether the person picked Copy; false for Cancel, a dismissal or no window to ask in.
    @MainActor public func confirmed(in window: NSWindow?) async -> Bool {
        guard let window else { return false }
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        return answer.button == Self.copyButton && !answer.isDismissal
    }
}
