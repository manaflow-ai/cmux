import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextOnboarding

/// The preview and mandatory answer before a classic snapshot is restored (``ClassicImportPreview/dialogSpec(atLaunch:)``).
@MainActor
struct ClassicImportConfirmation {
    static let importButton = ClassicImportPreview.importButton
    static let identifier = ClassicImportPreview.dialogIdentifier

    let preview: ClassicImportPreview
    let services: AppServices
    /// The launch asks: the prompt says where the import waits and its Cancel reads Not Now.
    var atLaunch = false

    func ask() async -> ClassicImportAnswer {
        let window = services.windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: \.isVisible)
        // No window yet (the launch's is still coming up): the dialog shows on its own rather than not at all.
        let answer = await CmuxDialogCenter.shared.present(spec(), in: window.map(CmuxDialogScope.window) ?? .app)
        if answer.button == Self.importButton { return .accepted }
        return answer.isDismissal ? .unanswered : .declined
    }

    func spec() -> CmuxDialogSpec { preview.dialogSpec(atLaunch: atLaunch) }
}
