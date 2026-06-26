import CmuxSettings
import Foundation

/// Host-supplied callbacks the package's section views invoke for
/// actions that live outside the catalog — clearing browser history,
/// opening the user's editor on cmux.json, sending feedback, posting
/// test notifications, restarting the app after a language change,
/// and launching the browser import workflow.
///
/// The package doesn't carry these implementations because they
/// depend on host-app services that have no place in a
/// Foundation-only settings package. The host implements this
/// protocol once and injects it via ``SettingsRuntime``; sections
/// check for `nil` callbacks and hide the corresponding buttons
/// when no host action is available.
@MainActor
public protocol SettingsHostActions: AnyObject {
    /// Deletes the user's browser history (visited-page suggestions,
    /// omnibar autocomplete cache). Idempotent.
    func clearBrowserHistory()

    /// Opens the cmux JSON config file in the user's preferred
    /// external editor. The package's inline editor still works;
    /// this is the escape hatch for users who prefer their own
    /// editor.
    func openConfigInExternalEditor()

    /// Launches the host's feedback flow (typically a "Send Feedback"
    /// URL or in-app form).
    func sendFeedback()

    /// Posts a synthetic test notification so the user can confirm
    /// the configured sound + behavior.
    func sendTestNotification()

    /// Opens System Settings to the cmux notifications pane so the
    /// user can grant / revoke OS-level notification permission.
    func openSystemNotificationSettings()

    /// Restarts the cmux app. Used after the user changes the
    /// language picker, which requires a full process restart.
    func restartApp()

    /// Launches the host's browser-import flow (Safari / Chrome /
    /// Firefox source picker + profile selection + cookie prompt).
    func openBrowserImportFlow()

    /// Asks the OS for notification authorization. No-op if the user
    /// has already responded (granted or denied).
    func requestNotificationAuthorization()

    /// Opens the cmux terminal config preview window (the legacy
    /// "Open Config" row in the App section). The host owns the
    /// window scene so the package can't open it directly.
    func openTerminalConfigWindow()

    /// Persists an explicit menu-bar-only preference change in the host app.
    ///
    /// The host pairs the visible `app.menuBarOnly` setting with any hidden
    /// safety marker it needs before changing the process activation policy.
    ///
    /// - Returns: `true` when the host handled persistence for this change.
    @discardableResult
    func setMenuBarOnly(_ enabled: Bool) -> Bool

    /// Opens the iOS pairing window, which shows a scannable QR code for
    /// pairing an iPhone with this Mac. The host owns the window so the
    /// package can't open it directly.
    func openMobilePairingWindow()

    /// Plays the currently configured notification sound so the user
    /// can preview it from the Settings UI.
    func previewNotificationSound(value: String, customFilePath: String)

    /// Returns the current number of saved browser-history entries, or
    /// `nil` if the host hasn't loaded the history store yet. The
    /// Browser section uses this to render a dynamic "N saved pages"
    /// subtitle next to the Clear History button.
    func browserHistoryEntryCount() -> Int?

    /// The current left-sidebar font size with the range + default the
    /// slider should use. Backed by the Ghostty config file, not
    /// `UserDefaults`, so it comes from the host rather than the catalog.
    func sidebarFontSize() -> SettingsFontSize

    /// Persists a new left-sidebar font size (in points) to the Ghostty
    /// config and live-reloads open windows. The host clamps to the valid
    /// range, so callers may pass any finite value.
    ///
    /// - Returns: `true` if the value was written and reloaded, `false` if
    ///   persistence failed. Callers should surface a save-failed message to
    ///   the user when this returns `false`, since the slider position no
    ///   longer reflects what is stored on disk.
    ///
    ///   The implementation performs the disk write off the main actor, so this
    ///   is `async`; call it from a `Task` in the slider/reset action.
    @discardableResult
    func setSidebarFontSize(_ points: Double) async -> Bool

    /// The current workspace tab-bar font size with its range + default.
    /// Backed by the Ghostty config file (`surface-tab-bar-font-size`).
    func surfaceTabBarFontSize() -> SettingsFontSize

    /// Persists a new workspace tab-bar font size (in points) and reloads.
    /// The host clamps to the valid range.
    ///
    /// - Returns: `true` if the value was written and reloaded, `false` if
    ///   persistence failed. See ``setSidebarFontSize(_:)`` for how callers
    ///   should react to a `false` result and why this is `async`.
    @discardableResult
    func setSurfaceTabBarFontSize(_ points: Double) async -> Bool

    /// Formats a point size for display next to a font-size slider
    /// (e.g. `12`, `13.5`), trimming trailing zeros.
    func formattedFontSize(_ points: Double) -> String

    /// The current status of the Mac-side iOS pairing host (the actual bound
    /// port, whether it fell back from the configured port, the active iOS
    /// connection count, the effective display name, and the routes the phone
    /// can reach this Mac on), or `nil` when the host has not started the
    /// mobile service yet (or in previews/tests). The Mobile section renders
    /// the bound-port indicator and diagnostics from this.
    ///
    /// Backed by host-app runtime state, so it lives here rather than in the
    /// catalog. See ``mobilePairingStatusUpdates()`` for live refresh.
    func mobilePairingStatus() -> MobilePairingStatusSnapshot?

    /// A stream that yields a fresh ``MobilePairingStatusSnapshot`` whenever the
    /// pairing host's status changes (listener bound/stopped, bound port
    /// changed, connection count changed). The Mobile section subscribes so the
    /// bound-port indicator and connection count stay live without polling.
    func mobilePairingStatusUpdates() -> AsyncStream<MobilePairingStatusSnapshot>

    /// The Mac's system name (e.g. `Host.current().localizedName`) used as the
    /// iOS pairing display name when the user sets no override. The Mobile
    /// section shows it as the display-name field placeholder. Empty when
    /// unavailable (previews/tests). This is a stable host value, not derived
    /// from the override, so the placeholder never goes stale as the override
    /// is edited.
    func mobilePairingDefaultDisplayName() -> String

    /// Applies an explicitly-requested iOS pairing port, checking availability
    /// first so a port already in use leaves the running listener untouched. The
    /// Mobile section calls this from its **Apply** button and renders the
    /// returned ``MobilePairingPortApplyResult`` as inline feedback; the live
    /// status stream then reflects the actual bound port.
    ///
    /// `async` because the availability check probes a real bind.
    func applyMobilePairingPort(_ port: Int) async -> MobilePairingPortApplyResult

    /// The full catalog of Command Palette commands a user can bind a custom
    /// keyboard shortcut to, in a stable display order. Backed by the host's
    /// live command contributions, so it lives here rather than in the catalog.
    /// The **Custom Commands** keyboard-shortcut section reads this to resolve a
    /// bound command id back to a title and to seed the picker's default list.
    /// Returns an empty array for hosts without a live palette (previews/tests).
    func commandShortcutCatalog() -> [CommandShortcutCatalogEntry]

    /// Ranks the command-shortcut catalog for `query` using the **same ranking
    /// engine as the Command Palette**, returning at most `limit` entries best
    /// first. An empty query yields the default catalog order (capped to
    /// `limit`). Returns an empty array for hosts without a live palette.
    func searchCommandShortcutCatalog(query: String, limit: Int) -> [CommandShortcutCatalogEntry]

    /// The user's currently-bound command shortcuts (`shortcuts.commands`),
    /// keyed by command id, parsed by the **host's** lenient config reader so a
    /// value written in *any* documented form (string `"cmd+n"`, object, or an
    /// unbind marker) resolves correctly. The Settings **Custom Commands**
    /// section uses this for the bound list and conflict detection rather than
    /// the package's object-only typed decode, which would silently drop a
    /// string-form binding. Returns an empty map for hosts without a config
    /// reader (previews/tests).
    func commandShortcuts() -> [String: StoredShortcut]

    /// The effective (override-or-default) shortcut for every built-in cmux
    /// action, keyed by action id, resolved by the **host's** lenient reader.
    /// The Custom Commands conflict check uses this instead of the package's
    /// `shortcuts.bindings` typed decode, which is object-only and all-or-nothing
    /// — a single string-form override there would blank the whole map and let a
    /// command silently shadow a rebound built-in. Empty for hosts without a
    /// config reader (previews/tests).
    func effectiveActionShortcuts() -> [String: StoredShortcut]

    /// The shortcuts of user-defined cmux config actions (cmux.json `actions`
    /// with a `shortcut`), as `(displayLabel, shortcut)` pairs. The runtime key
    /// router dispatches these *before* custom command shortcuts, so the Custom
    /// Commands conflict check must include them — otherwise a command could be
    /// bound to a keystroke a configured action already owns and never fire. The
    /// stored shortcut's first stroke is compared, which also catches chord
    /// prefixes. Returned as a list rather than a title-keyed map because action
    /// titles are free-form and may collide. Empty for hosts without a config
    /// store (previews/tests).
    func configuredActionShortcuts() -> [(label: String, shortcut: StoredShortcut)]

    /// Shows the Sleepy Mode screensaver as a non-locking preview (any key/click
    /// exits, no Touch ID). The host owns the overlay window.
    func sleepyModePreview()

    /// Starts Sleepy Mode using the user's current settings. The host owns the
    /// overlay window.
    func sleepyModeStart()

    /// The app-owned Sleepy Mode settings store, so the Preferences section binds
    /// to the same instance the overlay renderer reads (rather than a package
    /// singleton). Previews/tests get a fresh isolated store via the default.
    func sleepyModeStore() -> SleepyModeSettingsStore
}

public extension SettingsHostActions {
    func openMobilePairingWindow() {}

    /// Default no-op preview action for hosts without a Sleepy Mode overlay.
    func sleepyModePreview() {}
    /// Default no-op start action for hosts without a Sleepy Mode overlay.
    func sleepyModeStart() {}
    /// Default isolated store for previews/tests with no Sleepy Mode host.
    func sleepyModeStore() -> SleepyModeSettingsStore { SleepyModeSettingsStore() }

    /// Default no-op for package previews and tests that have no activation-policy host.
    func setMenuBarOnly(_ enabled: Bool) -> Bool { false }

    func browserHistoryEntryCount() -> Int? { nil }

    /// Default: no status, for hosts without a live mobile service (previews/tests).
    func mobilePairingStatus() -> MobilePairingStatusSnapshot? { nil }

    /// Default: an immediately-finished stream, for hosts without a live mobile service.
    func mobilePairingStatusUpdates() -> AsyncStream<MobilePairingStatusSnapshot> {
        AsyncStream { $0.finish() }
    }

    /// Default: empty, for hosts that cannot resolve the Mac's system name.
    func mobilePairingDefaultDisplayName() -> String { "" }

    /// Default: save-for-later, for hosts without a live mobile service (previews/tests).
    func applyMobilePairingPort(_ port: Int) async -> MobilePairingPortApplyResult {
        (1...65535).contains(port) ? .savedForLater(port: port) : .invalid(requestedPort: port)
    }

    /// Default: empty catalog, for hosts without a live Command Palette.
    func commandShortcutCatalog() -> [CommandShortcutCatalogEntry] { [] }

    /// Default: no bound command shortcuts, for hosts without a config reader.
    func commandShortcuts() -> [String: StoredShortcut] { [:] }

    /// Default: no built-in action shortcuts, for hosts without a config reader.
    func effectiveActionShortcuts() -> [String: StoredShortcut] { [:] }

    /// Default: no configured action shortcuts, for hosts without a config store.
    func configuredActionShortcuts() -> [(label: String, shortcut: StoredShortcut)] { [] }

    /// Default: a simple case-insensitive substring filter over the catalog so
    /// preview/test hosts still render a usable picker without the app's engine.
    func searchCommandShortcutCatalog(query: String, limit: Int) -> [CommandShortcutCatalogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = commandShortcutCatalog()
        let filtered: [CommandShortcutCatalogEntry]
        if trimmed.isEmpty {
            filtered = catalog
        } else {
            let needle = trimmed.lowercased()
            filtered = catalog.filter { entry in
                entry.title.lowercased().contains(needle)
                    || entry.subtitle.lowercased().contains(needle)
                    || entry.keywords.contains { $0.lowercased().contains(needle) }
            }
        }
        return limit >= 0 ? Array(filtered.prefix(limit)) : filtered
    }

    func sidebarFontSize() -> SettingsFontSize {
        SettingsFontSize(points: 12.5, minimum: 10, maximum: 20, defaultValue: 12.5)
    }

    func setSidebarFontSize(_ points: Double) async -> Bool { true }

    func surfaceTabBarFontSize() -> SettingsFontSize {
        SettingsFontSize(points: 11, minimum: 8, maximum: 14, defaultValue: 11)
    }

    func setSurfaceTabBarFontSize(_ points: Double) async -> Bool { true }

    func formattedFontSize(_ points: Double) -> String {
        let scaled = (points * 100).rounded()
        let whole = Int(scaled / 100)
        let fraction = abs(Int(scaled) % 100)
        if fraction == 0 { return "\(whole)" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)" }
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}

/// No-op ``SettingsHostActions`` for previews, tests, and any context
/// that renders settings without a live host. Lets the runtime expose a
/// non-optional ``SettingsRuntime/hostActions`` so section views never
/// have to branch on an optional host.
@MainActor
public final class NoopSettingsHostActions: SettingsHostActions {
    public init() {}
    public func clearBrowserHistory() {}
    public func openConfigInExternalEditor() {}
    public func sendFeedback() {}
    public func sendTestNotification() {}
    public func openSystemNotificationSettings() {}
    public func restartApp() {}
    public func openBrowserImportFlow() {}
    public func requestNotificationAuthorization() {}
    public func openTerminalConfigWindow() {}
    public func openMobilePairingWindow() {}
    /// No-op notification sound preview used by tests, previews, and
    /// package-only settings hosts.
    public func previewNotificationSound(value: String, customFilePath: String) {}
    public func browserHistoryEntryCount() -> Int? { nil }
}
