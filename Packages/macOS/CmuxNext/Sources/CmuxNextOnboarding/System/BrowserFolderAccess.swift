public import AppKit
public import CmuxNextBrowserImport
import CmuxNextDesign

/// Import from Browser's folder grants for the app: detection that reads only
/// granted folders, the open panel that asks for one, and the scope around an
/// import run.
@MainActor
public final class BrowserFolderAccess {
    private let environment: ImportEnvironment
    private let store: any BrowserFolderGrantStore

    public init(environment: ImportEnvironment = .live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                store: any BrowserFolderGrantStore = UserDefaultsBrowserFolderGrantStore()) {
        self.environment = environment
        self.store = store
    }

    private var grants: BrowserFolderGrants { BrowserFolderGrants(environment: environment, store: store) }

    public func detect() async -> [BrowserSource] {
        let grants = grants
        // The scan runs detached; cancelling the caller cancels it too, so it stops between browsers.
        let scan = Task.detached { grants.detect() }
        return await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
    }

    public func awaiting() async -> [ImportBrowser] {
        let grants = grants
        let scan = Task.detached { grants.awaiting() }
        return await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
    }

    public func folder(_ browser: ImportBrowser) -> URL? { grants.folder(browser) }

    /// The open panel at `browser`'s data folder, prompt Allow Access; only
    /// that folder is accepted and kept (`BrowserFolderGrants`).
    public func request(_ browser: ImportBrowser) async -> Bool {
        let grants = grants
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = grants.folder(browser)
        panel.prompt = OnboardingStrings.accessPanelPrompt
        panel.message = OnboardingStrings.accessPanelMessage(browser.displayName)
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.browserImport.folderAccess")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let picked = panel.url else { return false }
        return (try? grants.grant(picked, for: browser)) != nil
    }

    /// Keep in Sync over `store`, reading through the same folder grants as an import. Imported cookies
    /// are kept in sync into `cookies` (``ImportCookieSync``, its state beside the store's); `stopped`
    /// says once that a browser's cookies stopped syncing.
    public func historySync(store: ImportedDataStore, cookies: any CookieDestination, stopped: @escaping ImportCookieSync.Stopped,
                            deliver: @escaping ImportHistorySync.Deliver) -> ImportHistorySync {
        let cookieSync = ImportCookieSync(store: store, grants: grants, destination: cookies, keys: SafeStorageKeys().live(),
                                          stateDirectory: store.directory.appending(path: "cookie-sync", directoryHint: .isDirectory), stopped: stopped)
        return ImportHistorySync(store: store, grants: grants, cookies: cookieSync, deliver: deliver)
    }

    /// Puts the granted folders of the plan's browsers in scope; call the
    /// returned closure when the run ends.
    public func access(_ plan: ImportPlan) -> () -> Void {
        let grants = grants
        let scoped = Set(plan.items.map(\.profile.browser)).compactMap(grants.grantedFolder)
            .filter { $0.startAccessingSecurityScopedResource() }
        return { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
    }
}
