import AppKit
import CmuxNextDesign
import Foundation
import UniformTypeIdentifiers

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

/// The live steps: cmux dialogs in the key window, then the open panel.
@MainActor
struct LivePasswordCSVGuidePresenter: PasswordCSVGuidePresenting {
    private static let sourceField = "source"

    private var scope: CmuxDialogScope { (NSApp.keyWindow ?? NSApp.mainWindow).map { .window($0) } ?? .app }

    func chooseSource() async -> PasswordCSVSource? {
        let options = PasswordCSVSource.allCases.map { CmuxDialogOption(label: PasswordCSVGuideStrings.name($0), value: $0.rawValue) }
        let spec = CmuxDialogSpec(
            title: PasswordCSVGuideStrings.sourceTitle, lines: [PasswordCSVGuideStrings.sourceMessage],
            fields: [.choice(id: Self.sourceField, label: PasswordCSVGuideStrings.sourceLabel, options: options,
                             selected: PasswordCSVSource.apple.rawValue)],
            buttons: [CmuxDialogButton(id: "cancel", title: PasswordCSVGuideStrings.cancel, role: .cancel),
                      CmuxDialogButton(id: "continue", title: PasswordCSVGuideStrings.continueTitle, role: .default)],
            identifier: "cmux.dialog.passwordCSV.source")
        let answer = await CmuxDialogCenter.shared.present(spec, in: scope)
        guard answer.button == "continue", !answer.isDismissal else { return nil }
        return answer.values[Self.sourceField]?.text.flatMap(PasswordCSVSource.init(rawValue:))
    }

    func showSteps(_ source: PasswordCSVSource) async -> PasswordCSVStepAnswer {
        var buttons = [CmuxDialogButton(id: "cancel", title: PasswordCSVGuideStrings.cancel, role: .cancel)]
        if source == .apple { buttons.append(CmuxDialogButton(id: "open", title: PasswordCSVGuideStrings.openPasswords, role: .normal)) }
        buttons.append(CmuxDialogButton(id: "choose", title: PasswordCSVGuideStrings.chooseFile, role: .default))
        let spec = CmuxDialogSpec(title: PasswordCSVGuideStrings.stepsTitle(source), lines: PasswordCSVGuideStrings.steps(source),
                                  buttons: buttons, identifier: "cmux.dialog.passwordCSV.steps")
        let answer = await CmuxDialogCenter.shared.present(spec, in: scope)
        switch answer.isDismissal ? "cancel" : answer.button {
        case "open": return .openApp
        case "choose": return .chooseFile
        default: return .cancel
        }
    }

    /// The Passwords app (macOS 15 and later), else Safari, which exports passwords on older macOS.
    func openApp(_ source: PasswordCSVSource) {
        guard source == .apple else { return }
        let app = ["com.apple.Passwords", "com.apple.Safari"].lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        guard let app else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func chooseFile(_ source: PasswordCSVSource) async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.message = PasswordCSVStrings.prompt
        return await withCheckedContinuation { continuation in
            panel.beginForCmux { continuation.resume(returning: $0) }
        }
    }
}
