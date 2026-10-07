import Foundation

/// Where a password CSV comes from. Safari / Apple Passwords, 1Password and
/// Bitwarden keep their passwords where cmux does not read them, so cmux shows
/// the steps of each app's own CSV export before the open panel
/// (PASSWORDS-IMPORT-ANY-BROWSER). `other` is a CSV the person already has
/// (Chrome, Edge, Firefox, Proton Pass): straight to the open panel.
nonisolated enum PasswordCSVSource: String, CaseIterable, Sendable {
    case apple
    case onePassword
    case bitwarden
    case other
}

/// The person's answer on a source's steps sheet.
nonisolated enum PasswordCSVStepAnswer: Equatable, Sendable {
    case cancel
    /// Open the source app (Apple Passwords) and show the steps again.
    case openApp
    case chooseFile
}

/// The native steps of the guided CSV import. The live presenter shows cmux
/// dialogs and the open panel; tests answer with a script.
@MainActor
protocol PasswordCSVGuidePresenting {
    /// The source picker; nil when the person cancels.
    func chooseSource() async -> PasswordCSVSource?
    /// The export steps of `source`.
    func showSteps(_ source: PasswordCSVSource) async -> PasswordCSVStepAnswer
    /// Opens the app that exports `source` (Passwords, or Safari before macOS 15).
    func openApp(_ source: PasswordCSVSource)
    /// The open panel; nil when the person cancels.
    func chooseFile(_ source: PasswordCSVSource) async -> URL?
}

/// Guided CSV import, up to the file the person picked. Every step is the
/// person's own answer in a native sheet; nothing here reads a file.
@MainActor
struct PasswordCSVGuide {
    let presenter: any PasswordCSVGuidePresenting

    /// The CSV the person picked, or nil when they cancelled at any step.
    func run() async -> URL? {
        nil
    }
}
