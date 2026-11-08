public import CmuxNextCloud
public import CmuxNextDesign
public import AppKit
import CmuxNextCompat
import os

/// A Cloud chat start whose machine can't clone the folder from its git remote (cmux-tui
/// `link start-chat copy --on-seed-refusal ask` answering `seed_refused`): the person is asked
/// before the whole folder is copied instead, with cmux-tui's reason and what the copy would send.
/// A silent copy of a 12.8 GB folder ran a 16 GB machine's disk out ("Broken pipe").
public nonisolated struct CloudSeedRefusal: Equatable, Sendable {
    public static let code = "seed_refused"
    public static let copyButton = "copy"
    public static let connectGitHubButton = "connectGitHub"
    /// The seed plan's code for a private repository the machine can't read without the cmux GitHub App.
    public static let needsGitHub = "seed.needs_github"
    public static let identifier = "cmux.dialog.cloud.seedRefused"

    /// cmux-tui's words: why the machine can't clone it, and the copy's files and size.
    public let message: String
    public let machine: String
    /// The seed plan's code for the refusal (`not_git`, `submodule_local_work`, ...), for the log.
    public let fallbackCode: String?
    /// For ``needsGitHub``: the cmux GitHub App's install page, which Connect GitHub opens.
    public let installURL: URL?

    /// The person's answer to the dialog.
    public enum Choice: Equatable, Sendable { case copy, connectGitHub, cancel }

    /// The refusal in `answer`, or nil for any other answer.
    public init?(_ answer: CloudMoveCLI.Answer, machine: String) {
        guard !answer.ok, answer.errorCode == Self.code else { return nil }
        message = answer.error ?? Self.code
        self.machine = machine
        fallbackCode = answer.fallbackCode
        installURL = answer.fallbackCode == Self.needsGitHub ? answer.installURL.flatMap(URL.init(string:)) : nil
    }

    public var spec: CmuxDialogSpec {
        CmuxDialogSpec(
            title: String(format: String(localized: "cloud.seedRefused.title", defaultValue: "Copy the folder to %@?", table: "Cloud", bundle: .module), machine),
            lines: [message],
            buttons: [.cancel(), CmuxDialogButton(id: Self.copyButton, title: String(localized: "cloud.seedRefused.copy", defaultValue: "Copy the Folder", table: "Cloud", bundle: .module),
                                                  role: installURL == nil ? .default : .normal)]
                + (installURL == nil ? [] : [CmuxDialogButton(id: Self.connectGitHubButton, title: String(localized: "cloud.seedRefused.connectGitHub", defaultValue: "Connect GitHub", table: "Cloud", bundle: .module), role: .default)]),
            identifier: Self.identifier)
    }

    /// `copy` asking first (`.ask`); a refused seed asks the person in `window` and copies only on their
    /// Copy (`.copy`). Their Cancel, a dismissal or no window throws `declined(reason)`. The whole folder
    /// never goes silently: a 12.8 GB copy ran a 16 GB machine's disk out.
    @MainActor public static func copying<Copied>(machine: String, in window: @MainActor () -> NSWindow?, declined: (String) -> any Error,
                                                  _ copy: (CloudMoveCLI.SeedRefusal) async throws -> (CloudMoveCLI.Answer, Copied)) async throws -> (CloudMoveCLI.Answer, Copied) {
        try await copying(machine: machine, ask: { await $0.choice(in: window()) }, open: { _ = NSWorkspace.shared.openInForeground($0) },
                          declined: declined, copy)
    }

    /// ``copying(machine:in:declined:_:)`` with the question `ask` and `open` for Connect GitHub, which
    /// opens the install page and throws `declined(reason)`: the start's Retry seeds again once the App is in.
    @MainActor public static func copying<Copied>(machine: String, ask: (CloudSeedRefusal) async -> Choice, open: (URL) -> Void,
                                                  declined: (String) -> any Error,
                                                  _ copy: (CloudMoveCLI.SeedRefusal) async throws -> (CloudMoveCLI.Answer, Copied)) async throws -> (CloudMoveCLI.Answer, Copied) {
        let first = try await copy(.ask)
        guard let refused = CloudSeedRefusal(first.0, machine: machine) else { return first }
        Logger(subsystem: "com.cmuxterm.app.next", category: "cloud").info(
            "cloud seed refused on \(machine, privacy: .public): \(refused.fallbackCode ?? "unknown", privacy: .public)")
        switch await ask(refused) {
        case .copy: return try await copy(.copy)
        case .connectGitHub:
            if let url = refused.installURL { open(url) }
            throw declined(refused.message)
        case .cancel: throw declined(refused.message)
        }
    }

    /// The person's pick; ``Choice/cancel`` for Cancel, a dismissal or no window to ask in.
    @MainActor public func choice(in window: NSWindow?) async -> Choice {
        guard let window else { return .cancel }
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        guard !answer.isDismissal else { return .cancel }
        switch answer.button {
        case Self.copyButton: return .copy
        case Self.connectGitHubButton where installURL != nil: return .connectGitHub
        default: return .cancel
        }
    }
}
