public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextSettings
public import Foundation
import os

/// What `browser.import.enabled` asks of the App (`AppServices+BrowserImportHost`).
@MainActor
public protocol BrowserImportGateHost: AnyObject {
    /// The settings the value is read from; nil while they are not loaded (on).
    var browserImportSettings: SettingsController? { get }
    /// Turned off: the browser tab's import offer goes and an open Import from Browser window closes.
    func browserImportTurnedOff()
    /// Keep in Sync stops (or goes back to) re-reading other browsers' history.
    func setBrowserHistorySyncPaused(_ paused: Bool) async
}

/// `browser.import.enabled` (Settings > Browser > Import; on by default). Off, cmux's Import from
/// Browser entry points leave: the File menu items, palette actions and context-menu rows below
/// (a run is refused with the App's turned-off reason), the import tool window, the browser tab's
/// import offer and the import suggestion cards in Settings › Import. Nothing imports by itself
/// either: Keep in Sync stops re-reading other browsers' history, a paused card job does not resume
/// and a scan in flight is dropped. Data already imported stays, and Remove Imported Data still
/// removes it.
@MainActor
public struct BrowserImportGate {
    /// The actions that bring data over from another browser or app.
    public static let actionIDs: Set<ActionID> = [
        "importFromBrowser", "bookmark.importFromBrowser", "browser.importFromFiles", "browser.importCookies",
        "import.list", "import.card", "import.suggest", "import.open", "browser.showCookieImportBanner",
    ]

    private weak var host: (any BrowserImportGateHost)?

    public init(host: any BrowserImportGateHost) {
        self.host = host
    }

    /// The setting's value; on while settings are not loaded.
    public var isEnabled: Bool { host?.browserImportSettings?.snapshot.browserImportEnabled ?? BrowserImportSetting.fallback }

    /// Turns the import actions off in every surface while the setting is off, saying `reason`.
    public func install(into registry: ActionRegistry, reason: @escaping @MainActor () -> String) {
        let gate = self
        registry.settingOffReason = { id in
            guard Self.actionIDs.contains(id), !gate.isEnabled else { return nil }
            return reason()
        }
    }

    /// The launch read's value, before the cards start, so an off setting never lets them scan.
    public static func prime(_ snapshot: CmuxConfigSnapshot) {
        ImportSuggestionsCenter.shared.importEnabled = snapshot.browserImportEnabled
    }

    /// Follows the setting: the suggestion cards, the browser tab's offer, the import window and Keep in Sync.
    public func follow(_ settings: SettingsController) -> Task<Void, Never> {
        let gate = self
        // task-owner: OnboardingService.importSettingFollow (cancelled when settings are replaced)
        return Task {
            var last: Bool?
            for await on in ObservationStream({ settings.snapshot.browserImportEnabled }) {
                guard let host = gate.host else { return }
                ImportSuggestionsCenter.shared.importEnabled = on
                if !on { host.browserImportTurnedOff() }
                // Keep in Sync is made on first use: leave it unmade while import was never off.
                if !on || last == false { await host.setBrowserHistorySyncPaused(!on) }
                last = on
            }
        }
    }
}

/// An import run refused because `browser.import.enabled` is off (a window or card left on screen).
public struct BrowserImportTurnedOff: LocalizedError {
    public let errorDescription: String?

    public init(_ reason: String) {
        errorDescription = reason
    }
}

/// Tells a detached import scan to stop: set from its task's cancellation handler, read by the scan
/// before each source (`ImportScanner.shouldStop`).
nonisolated final class ImportScanStop: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    var isSet: Bool { flag.withLock { $0 } }

    func set() { flag.withLock { $0 = true } }
}
