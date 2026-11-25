import CmuxNextActions
import CmuxNextAppTry
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextWakeups
import Foundation

// The four CLI-verb palette rows (PaletteVerbActions): one-line forwards to the App's owners.
extension AppServices: PaletteVerbHost {
    var paletteLocalDaemon: DaemonService { machines.local }
    var paletteCLI: BundledExecutable { bundledCLI }
    var paletteWork: BackgroundWork { work }
    func paletteRequireSpaces() throws { try AppActionContext(services: self).requireRooms() }
    func paletteRoom(_ invocation: ActionInvocation) throws -> ProfileID { try AppActionContext(services: self).room(invocation).id }
    func palettePane(_ invocation: ActionInvocation) -> PaneModel? { AppActionContext(services: self).paneController(invocation)?.pane }
    func paletteDaemon(for pane: PaneModel) -> DaemonService { machines.daemon(forPane: pane) }
    func paletteResourcePath(of pane: PaneModel) -> PaneResourcePath? { resourcePath(of: pane) }
    func paletteResetLibrary(_ cli: URL) async throws { _ = try await SettingsCustomizeLibrary.reset(cli: cli, settingsFile: settings?.file.url) }
    func paletteMessage(_ error: any Error) -> String { (error as? PageError)?.message ?? (error as? ActionFailure)?.message ?? error.localizedDescription }
    func paletteToast(_ message: String, duration: Duration) { CLIRowToast(id: "palette-verb", category: "palette-verb").show(message, in: windows.active?.window, duration: duration) }
}
