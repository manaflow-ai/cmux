import AppKit
import CmuxNextDesign

/// The preview and mandatory answer before a classic snapshot is restored.
@MainActor
struct ClassicImportConfirmation {
    static let importButton = "import"
    static let identifier = "cmux.dialog.classicImport"

    let plan: ClassicImportPlan
    let services: AppServices

    func ask() async -> Bool {
        let window = services.windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: \.isVisible)
        guard let window else { return false }
        let answer = await CmuxDialogCenter.shared.present(spec(), in: .window(window))
        return answer.button == Self.importButton
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
