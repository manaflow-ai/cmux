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

/// Guided CSV import, up to the file the person picked. Every step is the
/// person's own answer in a native sheet; nothing here reads a file.
@MainActor
struct PasswordCSVGuide {
    let presenter: any PasswordCSVGuidePresenting

    /// The CSV the person picked, or nil when they cancelled at any step.
    func run() async -> URL? {
        guard let source = await presenter.chooseSource() else { return nil }
        if source != .other {
            // Each pass waits for the person's answer on the steps sheet; Open Passwords shows it again.
            var answer = await presenter.showSteps(source)
            while answer == .openApp {
                presenter.openApp(source)
                answer = await presenter.showSteps(source)
            }
            guard answer == .chooseFile else { return nil }
        }
        return await presenter.chooseFile(source)
    }
}
