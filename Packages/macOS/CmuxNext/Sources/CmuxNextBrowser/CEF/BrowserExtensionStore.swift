public import AppKit
public import Observation

/// Where a `BrowserExtensionStore` reads and changes extension state: a
/// Chromium profile (`CEFExtensionBackend`) or a mock (demos, tests).
@MainActor
public protocol BrowserExtensionBackend: AnyObject {
    /// Enable/disable, remove, pin, options and load unpacked are available.
    var supportsManagement: Bool { get }
    /// The installed extensions and shortcuts, or nil while no browser of
    /// the profile is live (the store keeps its last lists).
    func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])?
    func setEnabled(_ id: String, _ enabled: Bool) -> Bool
    func uninstall(_ id: String) -> Bool
    /// Reloads an extension, also a terminated (crashed) one.
    func reload(_ id: String) -> Bool
    /// Moves a pinned extension to `index` among the pinned ones.
    func movePinned(_ id: String, to index: Int) -> Bool
    /// Pinned extensions can be reordered (fork API v6).
    var supportsPinnedOrder: Bool { get }
    func setPinned(_ id: String, _ pinned: Bool) -> Bool
    func openOptions(_ id: String, from tab: (any BrowserTab)?) -> Bool
    func loadUnpacked(at path: String) -> Bool
    /// Dispatches `commands.onCommand` (not `_execute_action`).
    func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool
}

extension BrowserExtensionBackend {
    /// Backends without an order API keep Chromium's pinned order.
    public var supportsPinnedOrder: Bool { false }
    public func movePinned(_ id: String, to index: Int) -> Bool { false }
}

/// The installed extensions and their keyboard shortcuts of one browser
/// profile, plus the chrome://extensions operations on them. Chromium owns
/// the state; this is a read-through mirror refreshed on the fork's
/// `CMUX_EXTENSIONS_CHANGED` / action events.
@Observable
public final class BrowserExtensionStore {
    public let profileID: BrowserProfileID
    public private(set) var extensions: [BrowserExtensionInfo] = []
    public private(set) var commands: [BrowserExtensionCommand] = []
    @ObservationIgnored private let backend: any BrowserExtensionBackend

    public init(profile: BrowserProfileID, backend: any BrowserExtensionBackend) {
        profileID = profile
        self.backend = backend
    }

    public var supportsManagement: Bool { backend.supportsManagement }

    public func refresh() {
        guard let snapshot = backend.snapshot() else { return }
        if snapshot.commands != commands { commands = snapshot.commands }
        if snapshot.extensions != extensions { extensions = snapshot.extensions }
    }

    /// Extensions whose process crashed or was killed (Chromium's
    /// terminated set); they stay off until reloaded.
    public var crashed: [BrowserExtensionInfo] { extensions.filter(\.isTerminated) }

    /// Reloads an extension, also a crashed one: fork API v5
    /// `cmux_ext_reload`; older forks disable then enable (Chromium moves a
    /// terminated extension to the disabled set and loads it on enable).
    public func reload(_ id: String) -> Bool { perform { $0.reload(id) } }

    /// Moves a pinned extension among the pinned ones (the toolbar drag);
    /// Chromium persists the order per profile.
    public func movePinned(_ id: String, to index: Int) -> Bool { perform { $0.movePinned(id, to: index) } }
    public var supportsPinnedOrder: Bool { backend.supportsPinnedOrder }

    public func setEnabled(_ id: String, _ enabled: Bool) -> Bool { perform { $0.setEnabled(id, enabled) } }
    public func uninstall(_ id: String) -> Bool { perform { $0.uninstall(id) } }
    public func setPinned(_ id: String, _ pinned: Bool) -> Bool { perform { $0.setPinned(id, pinned) } }

    /// Opens the options page as a tab of `tab`'s pane (Chromium adds the tab
    /// to that tab's window; the host adopts it).
    public func openOptions(_ id: String, from tab: (any BrowserTab)? = nil) -> Bool {
        supportsManagement && backend.openOptions(id, from: tab)
    }

    /// Loads an unpacked extension directory into this profile (persistent,
    /// like chrome://extensions "Load unpacked").
    public func loadUnpacked(at path: String) -> Bool { perform { $0.loadUnpacked(at: path) } }

    /// Runs a shortcut with `tab` as the active tab. `_execute_action` clicks
    /// the toolbar action (anchored to its button, or to the Extensions
    /// button when it is not pinned); others dispatch `commands.onCommand`.
    public func run(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool {
        if command.isExecuteAction, let host = tab as? any BrowserExtensionActionHosting {
            host.requestExtensionAction(command.extensionID)
            return true
        }
        return backend.runCommand(command, in: tab)
    }

    /// The installed extension with id `text`, else the one whose name
    /// matches it case-insensitively.
    public func extensionInfo(matching text: String) -> BrowserExtensionInfo? {
        extensions.first { $0.id == text }
            ?? extensions.first { $0.name.localizedCaseInsensitiveCompare(text) == .orderedSame }
    }

    /// The first shortcut matching `event`, if any.
    public func command(matching event: NSEvent) -> BrowserExtensionCommand? {
        commands.first { $0.matches(event) }
    }

    private func perform(_ call: (any BrowserExtensionBackend) -> Bool) -> Bool {
        guard supportsManagement else { return false }
        let ok = call(backend)
        refresh()
        return ok
    }
}
