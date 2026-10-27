public import CmuxNextBrowserImport
public import CmuxNextWakeups
public import Foundation

/// What the cards need from the App, which owns the importer's stores: the
/// same import run the Import from Browser window uses, what was imported
/// before, and Settings at a page route.
@MainActor
public struct ImportCardsHost {
    /// Runs one plan through the App's importer (cookies into the profile's Chromium store,
    /// history and bookmarks into its stores) with the job's Keychain reads, reporting progress
    /// on the main actor.
    public var runImport: (ImportPlan, any SafeStorageKeyProviding, @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary
    /// The browser profiles imported before (`ImportSourceRecord.sourceKey`, `chrome/Default`).
    public var importedProfiles: () async -> Set<String>
    /// Opens Settings at a page route (`#/settings/import`).
    public var openSettings: (String) -> Void
    /// Runs Import Workspaces from Classic cmux, the same run as the `workspace.importClassic`
    /// action: its own preview and confirmation, the migration ledger (so nothing comes over
    /// twice) and its toast. Reports the share of classic workspaces handled, 0...1, on the main
    /// actor. Returns how many workspaces this run opened, nil when the person declined the preview.
    public var importClassic: (@escaping @MainActor (Double) -> Void) async throws -> Int?
    /// The app's one fan-out of app notices: the cards rescan when cmux comes forward.
    public var appEvents: AppEvents

    public init(runImport: @escaping (ImportPlan, any SafeStorageKeyProviding, @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary,
                importedProfiles: @escaping () async -> Set<String>,
                openSettings: @escaping (String) -> Void,
                importClassic: @escaping (@escaping @MainActor (Double) -> Void) async throws -> Int?,
                appEvents: AppEvents) {
        self.runImport = runImport
        self.importedProfiles = importedProfiles
        self.openSettings = openSettings
        self.importClassic = importClassic
        self.appEvents = appEvents
    }
}
