import AppKit
import CmuxNextDesign
import CmuxNextOnboarding

/// How the person answered the classic import preview.
enum ClassicImportAnswer: Equatable {
    /// Import pressed.
    case accepted
    /// Cancel pressed (or Escape): the launch's run records it and stops asking.
    case declined
    /// Nobody answered: the window closed under the dialog or the app quit. The next launch asks again.
    case unanswered
}

/// The preview and mandatory answer before a classic snapshot is restored.
@MainActor
struct ClassicImportConfirmation {
    static let importButton = "import"
    static let identifier = "cmux.dialog.classicImport"

    let plan: ClassicImportPlan
    let services: AppServices

    func ask() async -> ClassicImportAnswer {
        let window = services.windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: \.isVisible)
        // No window yet (the launch's is still coming up): the dialog shows on its own rather than not at all.
        let answer = await CmuxDialogCenter.shared.present(spec(), in: window.map(CmuxDialogScope.window) ?? .app)
        if answer.button == Self.importButton { return .accepted }
        return answer.isDismissal ? .unanswered : .declined
    }

    func spec() -> CmuxDialogSpec {
        return CmuxDialogSpec(
            title: ClassicImportStrings.previewTitle,
            lines: ClassicImportStrings.previewLines(plan),
            buttons: [
                .cancel(ConfirmationStrings.cancel),
                CmuxDialogButton(id: Self.importButton, title: ClassicImportStrings.previewButton, role: .default),
            ],
            identifier: Self.identifier
        )
    }
}
