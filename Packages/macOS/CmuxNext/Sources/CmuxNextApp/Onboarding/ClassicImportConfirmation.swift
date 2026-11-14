import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextOnboarding

/// The preview and mandatory answer before a classic snapshot is restored.
@MainActor
struct ClassicImportConfirmation {
    static let importButton = "import"
    static let identifier = "cmux.dialog.classicImport"

    let preview: ClassicImportPreview
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
            lines: ClassicImportStrings.previewLines(preview),
            buttons: [
                .cancel(ConfirmationStrings.cancel),
                CmuxDialogButton(id: Self.importButton, title: ClassicImportStrings.previewButton, role: .default),
            ],
            identifier: Self.identifier
        )
    }
}
