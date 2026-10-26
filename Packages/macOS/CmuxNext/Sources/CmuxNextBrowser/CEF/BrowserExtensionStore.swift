public import AppKit
public import Observation

/// Where a `BrowserExtensionStore` reads and changes extension state: a
/// Chromium profile (`CEFExtensionBackend`) or a mock (demos, tests).
///
/// A change returns whether it was sent, not Chromium's verdict: with the Chromium Host the browser
/// is another process, so the verdict comes back as an extension event that refreshes the snapshot
/// (plans/cmux-next/chrome-parity/p01-process.md, task 026). The store decides in the person's turn
/// what Chromium would refuse, from the extension's own state.
@MainActor
public protocol BrowserExtensionBackend: AnyObject {
    /// Enable/disable, remove, pin, options and load unpacked are available.
    var supportsManagement: Bool { get }
    /// The installed extensions and shortcuts, or nil while no browser of
    /// the profile is live or its lists have no value yet (the store keeps
    /// its last lists).
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
    public func reload(_ id: String) -> Bool {
        change(id, when: { _ in true }, send: { $0.reload(id) }) { $0.isTerminated = false }
    }

    /// Moves a pinned extension among the pinned ones (the toolbar drag);
    /// Chromium persists the order per profile. The toolbar's actions show
    /// the order, so nothing in these lists changes first.
    public func movePinned(_ id: String, to index: Int) -> Bool {
        change(id, when: \.isPinned, send: { $0.movePinned(id, to: index) }) { _ in }
    }
    public var supportsPinnedOrder: Bool { backend.supportsPinnedOrder }

    /// Chromium refuses to change what policy installed, must keep enabled or
    /// blocklisted (extensions::ManagementPolicy::UserMayModifySettings and
    /// MustRemainEnabled, chrome/browser/extensions/extension_service.cc):
    /// the menus' own `canToggle`.
    public func setEnabled(_ id: String, _ enabled: Bool) -> Bool {
        change(id, when: \.canToggle, send: { $0.setEnabled(id, enabled) }) { $0.isEnabled = enabled }
    }

    /// Gone at once, as its chrome://extensions card goes; the next list confirms it.
    public func uninstall(_ id: String) -> Bool {
        change(id, when: \.canRemove, send: { $0.uninstall(id) }, shows: nil)
    }

    /// Only an extension with a toolbar action pins.
    public func setPinned(_ id: String, _ pinned: Bool) -> Bool {
        change(id, when: \.hasAction, send: { $0.setPinned(id, pinned) }) { $0.isPinned = pinned }
    }

    /// Opens the options page as a tab of `tab`'s pane (Chromium adds the tab
    /// to that tab's window; the host adopts it). Only an enabled extension
    /// with an options page has one to open, as Chrome's extension menu
    /// decides (OptionsPageInfo::HasOptionsPage,
    /// chrome/browser/extensions/extension_context_menu_model.cc).
    public func openOptions(_ id: String, from tab: (any BrowserTab)? = nil) -> Bool {
        guard supportsManagement, let info = extensions.first(where: { $0.id == id }), info.isEnabled, info.optionsURL != nil else {
            return false
        }
        return backend.openOptions(id, from: tab)
    }

    /// Loads an unpacked extension directory into this profile (persistent,
    /// like chrome://extensions "Load unpacked"). It shows when Chromium's
    /// install event refreshes the lists.
    public func loadUnpacked(at path: String) -> Bool {
        guard supportsManagement, backend.loadUnpacked(at: path) else { return false }
        refresh()
        return true
    }

    /// Runs a shortcut with `tab` as the active tab. `_execute_action` clicks
    /// the toolbar action (anchored to its button, or to the Extensions
    /// button when it is not pinned); others dispatch `commands.onCommand`.
    public func run(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool {
        if command.isExecuteAction, let host = tab as? any BrowserExtensionActionHosting {
            host.requestExtensionAction(command.extensionID)
            return true
        }
        guard extensions.first(where: { $0.id == command.extensionID })?.isEnabled == true else { return false }
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

    /// A management change: refused in this turn when the extension is unknown or `allowed` says
    /// Chromium would refuse it, else sent and shown at once: `shows` edits the extension's entry,
    /// nil removes it and its shortcuts. The refresh after it reads Chromium's state in process; in
    /// host mode the lists are pending until the host applied the change, and its extension event
    /// confirms or reverts what shows.
    private func change(_ id: String, when allowed: (BrowserExtensionInfo) -> Bool,
                        send: (any BrowserExtensionBackend) -> Bool,
                        shows: ((inout BrowserExtensionInfo) -> Void)?) -> Bool {
        guard supportsManagement, let index = extensions.firstIndex(where: { $0.id == id }), allowed(extensions[index]),
              send(backend) else { return false }
        if let shows {
            var shown = extensions[index]
            shows(&shown)
            if shown != extensions[index] { extensions[index] = shown }
        } else {
            extensions.remove(at: index)
            if commands.contains(where: { $0.extensionID == id }) { commands.removeAll { $0.extensionID == id } }
        }
        refresh()
        return true
    }
}
