import CmuxNextDesign
import CmuxNextUpdater

extension UpdaterService {
    /// Wires the updater to the App: the sheet (failure details, managed
    /// policy, required version, or no rail circle on screen), and a
    /// relaunch into an update that keeps every terminal (no quit sheet).
    func attach(sheet: UpdateSheetController, services: AppServices) {
        presentUpdateUI = { [weak services] in sheet.present(in: services?.windows.active?.window) }
        willRelaunch = { [weak services] in services?.quit.origins.record(.explicit(.keep)) }
        showsIndicator = { DesignSettings.shared.rail != .off }
        isSheetPresented = { sheet.isPresented }
    }
}
