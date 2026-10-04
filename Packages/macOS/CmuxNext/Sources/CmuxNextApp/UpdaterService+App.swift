import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextUpdater

extension UpdaterService {
    /// Wires the updater to the App: the sheet (failure details, managed
    /// policy, required version, or no Settings item to carry the update
    /// badge, R53), and a
    /// relaunch into an update that keeps every terminal (no quit sheet).
    func attach(sheet: UpdateSheetController, services: AppServices) {
        presentUpdateUI = { [weak services] in sheet.present(in: services?.windows.active?.window) }
        willRelaunch = { [weak services] in services?.quit.origins.record(.explicit(.keep)) }
        showsIndicator = { [weak services] in services?.sidebarLayout.document.firstItem(with: .builtIn(.settings)) != nil }
        isSheetPresented = { sheet.isPresented }
    }
}
