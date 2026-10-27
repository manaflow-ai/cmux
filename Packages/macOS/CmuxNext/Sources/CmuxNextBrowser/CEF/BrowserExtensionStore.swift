public import AppKit
public import Observation

/// Where a `BrowserExtensionStore` reads and changes extension state: a
/// Chromium profile (`CEFExtensionBackend`) or a mock (demos, tests).
///
/// A management call returns whether it was sent; `answered` then gets Chromium's verdict once:
/// in the call's turn in process, in the turn of the host's REPLY with the Chromium Host, where the
/// browser is another process (plans/cmux-next/chrome-parity/p01-process.md, task 026; false for no
/// answer). The store decides in the person's turn what Chromium would refuse, from the extension's
/// own state, and sends nothing then.
@MainActor
public protocol BrowserExtensionBackend: AnyObject {
    /// Enable/disable, remove, pin, options and load unpacked are available.
    var supportsManagement: Bool { get }
    /// The installed extensions and shortcuts, or nil while no browser of
    /// the profile is live or its lists have no value yet (the store keeps
    /// its last lists).
    func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])?
    func setEnabled(_ id: String, _ enabled: Bool, answered: @escaping (Bool) -> Void) -> Bool
    func uninstall(_ id: String, answered: @escaping (Bool) -> Void) -> Bool
    /// Reloads an extension, also a terminated (crashed) one.
    func reload(_ id: String, answered: @escaping (Bool) -> Void) -> Bool
    /// Moves a pinned extension to `index` among the pinned ones.
    func movePinned(_ id: String, to index: Int, answered: @escaping (Bool) -> Void) -> Bool
    /// Pinned extensions can be reordered (fork API v6).
    var supportsPinnedOrder: Bool { get }
    func setPinned(_ id: String, _ pinned: Bool, answered: @escaping (Bool) -> Void) -> Bool
    func openOptions(_ id: String, from tab: (any BrowserTab)?, answered: @escaping (Bool) -> Void) -> Bool
    func loadUnpacked(at path: String, answered: @escaping (Bool) -> Void) -> Bool
    /// Dispatches `commands.onCommand` (not `_execute_action`); a post with no answer.
    func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool
}

extension BrowserExtensionBackend {
    /// Backends without an order API keep Chromium's pinned order.
    public var supportsPinnedOrder: Bool { false }
    public func movePinned(_ id: String, to index: Int, answered: @escaping (Bool) -> Void) -> Bool { false }
}

/// The installed extensions and their keyboard shortcuts of one browser
/// profile, plus the chrome://extensions operations on them. Chromium owns
/// the state; this is a read-through mirror refreshed on the fork's
/// `CMUX_EXTENSIONS_CHANGED` / action events and at each change's answer.
///
/// Every change returns false when it was refused in this turn (nothing
/// sent); `answered` then gets Chromium's verdict once, after the store took
/// Chromium's lists.
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
    @discardableResult
    public func reload(_ id: String, answered: @escaping (Bool) -> Void = { _ in }) -> Bool {
        change(id, when: { _ in true }, answered: answered, send: { $0.reload(id, answered: $1) }) { $0.isTerminated = false }
    }

    /// Moves a pinned extension among the pinned ones (the toolbar drag);
    /// Chromium persists the order per profile. The toolbar's actions show
    /// the order, so nothing in these lists changes first.
    @discardableResult
    public func movePinned(_ id: String, to index: Int, answered: @escaping (Bool) -> Void = { _ in }) -> Bool {
        change(id, when: \.isPinned, answered: answered, send: { $0.movePinned(id, to: index, answered: $1) }) { _ in }
    }
    public var supportsPinnedOrder: Bool { backend.supportsPinnedOrder }

    /// Chromium refuses to change what policy installed, must keep enabled or
    /// blocklisted (extensions::ManagementPolicy::UserMayModifySettings and
    /// MustRemainEnabled, chrome/browser/extensions/extension_service.cc):
    /// the menus' own `canToggle`.
    @discardableResult
    public func setEnabled(_ id: String, _ enabled: Bool, answered: @escaping (Bool) -> Void = { _ in }) -> Bool {
        change(id, when: \.canToggle, answered: answered, send: { $0.setEnabled(id, enabled, answered: $1) }) { $0.isEnabled = enabled }
    }

    /// Gone at once, as its chrome://extensions card goes; Chromium's list at the answer confirms it.
    @discardableResult
    public func uninstall(_ id: String, answered: @escaping (Bool) -> Void = { _ in }) -> Bool {
        change(id, when: \.canRemove, answered: answered, send: { $0.uninstall(id, answered: $1) }, shows: nil)
    }

    /// Only an extension with a toolbar action pins.
    @discardableResult
    public func setPinned(_ id: String, _ pinned: Bool, answered: @escaping (Bool) -> Void = { _ in }) -> Bool {
        change(id, when: \.hasAction, answered: answered, send: { $0.setPinned(id, pinned, answered: $1) }) { $0.isPinned = pinned }
    }

    /// Opens the options page as a tab of `tab`'s pane (Chromium adds the tab
    /// to that tab's window; the host adopts it). Only an enabled extension
    /// with an options page has one to open, as Chrome's extension menu
    /// decides (OptionsPageInfo::HasOptionsPage,
    /// chrome/browser/extensions/extension_context_menu_model.cc). `answered`
    /// gets whether Chromium opened it.
    @discardableResult
    public func openOptions(_ id: String, from tab: (any BrowserTab)? = nil, answered: @escaping (Bool) -> Void = { _ in }) -> Bool {
        guard supportsManagement, let info = extensions.first(where: { $0.id == id }), info.isEnabled, info.optionsURL != nil else {
            return false
        }
        return backend.openOptions(id, from: tab, answered: answered)
    }

    /// Loads an unpacked extension directory into this profile (persistent,
    /// like chrome://extensions "Load unpacked"). `answered` gets whether
    /// Chromium loaded it, after the store took Chromium's lists.
    @discardableResult
    public func loadUnpacked(at path: String, answered: @escaping (Bool) -> Void = { _ in }) -> Bool {
        guard supportsManagement else { return false }
        return backend.loadUnpacked(at: path) { [weak self] loaded in
            self?.refresh()
            answered(loaded)
        }
    }

    /// Runs a shortcut with `tab` as the active tab. `_execute_action` clicks
    /// the toolbar action (anchored to its button, or to the Extensions
    /// button when it is not pinned); others dispatch `commands.onCommand`,
    /// only for a shortcut the enabled extension registered, as Chrome's
    /// ExtensionKeybindingRegistry dispatches only what its list holds
    /// (chrome/browser/extensions/extension_keybinding_registry.cc).
    public func run(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool {
        if command.isExecuteAction, let host = tab as? any BrowserExtensionActionHosting {
            host.requestExtensionAction(command.extensionID)
            return true
        }
        guard extensions.first(where: { $0.id == command.extensionID })?.isEnabled == true,
              commands.contains(where: { $0.extensionID == command.extensionID && $0.name == command.name }) else { return false }
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
    /// Chromium would refuse it, else shown at once and sent: `shows` edits the extension's entry,
    /// nil removes it and its shortcuts. At Chromium's answer (in this turn in process; at the
    /// host's REPLY in host mode, which clears the lists' pending marks) the store takes Chromium's
    /// lists, so a refused change reverts and an applied one shows Chromium's state; then
    /// `answered` gets the verdict. A change that was not sent restores what showed before it.
    private func change(_ id: String, when allowed: (BrowserExtensionInfo) -> Bool, answered: @escaping (Bool) -> Void,
                        send: (any BrowserExtensionBackend, @escaping (Bool) -> Void) -> Bool,
                        shows: ((inout BrowserExtensionInfo) -> Void)?) -> Bool {
        guard supportsManagement, let index = extensions.firstIndex(where: { $0.id == id }), allowed(extensions[index]) else {
            return false
        }
        let before = (extensions: extensions, commands: commands)
        if let shows {
            var shown = extensions[index]
            shows(&shown)
            if shown != extensions[index] { extensions[index] = shown }
        } else {
            extensions.remove(at: index)
            if commands.contains(where: { $0.extensionID == id }) { commands.removeAll { $0.extensionID == id } }
        }
        let sent = send(backend) { [weak self] accepted in
            self?.refresh()
            answered(accepted)
        }
        if !sent {
            if extensions != before.extensions { extensions = before.extensions }
            if commands != before.commands { commands = before.commands }
        }
        return sent
    }
}
