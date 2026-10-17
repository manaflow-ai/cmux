public import AppKit
public import Foundation
public import Observation

/// The installed extensions and keyboard shortcuts of one Chromium browser
/// profile, plus the `chrome://extensions` operations on them.
///
/// Chromium owns the state and persists it in the profile directory; this is
/// a read-through mirror refreshed on the fork's extension-changed and action
/// events. One store exists per profile, created by the Chromium engine.
///
/// ```swift
/// let store = BrowserExtensionStore(profileID: profile.id, backend: backend)
/// store.refresh()
/// _ = store.setPinned(info.id, true)
/// ```
@MainActor
@Observable
public final class BrowserExtensionStore {
    /// The cmux browser profile this store mirrors.
    public let profileID: UUID
    /// The installed extensions, sorted by name.
    public private(set) var extensions: [BrowserExtensionInfo] = []
    /// The active keyboard shortcuts.
    public private(set) var commands: [BrowserExtensionCommand] = []
    @ObservationIgnored private let backend: any BrowserExtensionBackend

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - profileID: The cmux browser profile.
    ///   - backend: Where the state lives (the Chromium profile, or a mock).
    public init(profileID: UUID, backend: any BrowserExtensionBackend) {
        self.profileID = profileID
        self.backend = backend
    }

    /// True when the engine supports managing extensions (not only listing actions).
    public var supportsManagement: Bool { backend.supportsManagement }

    /// True when pinned extensions can be reordered.
    public var supportsPinnedOrder: Bool { backend.supportsPinnedOrder }

    /// Re-reads the lists. Keeps the last lists while no browser of the profile is live.
    public func refresh() {
        guard let snapshot = backend.snapshot() else { return }
        if snapshot.commands != commands { commands = snapshot.commands }
        if snapshot.extensions != extensions { extensions = snapshot.extensions }
    }

    /// Extensions whose process crashed or was killed; they stay off until reloaded.
    public var crashed: [BrowserExtensionInfo] { extensions.filter(\.isTerminated) }

    /// Reloads an extension, also a crashed one.
    public func reload(_ id: String) -> Bool { perform { $0.reload(id) } }

    /// Moves a pinned extension among the pinned ones (the toolbar drag);
    /// Chromium persists the order per profile.
    public func movePinned(_ id: String, to index: Int) -> Bool {
        supportsPinnedOrder && perform { $0.movePinned(id, to: index) }
    }

    /// Enables or disables an extension.
    public func setEnabled(_ id: String, _ enabled: Bool) -> Bool { perform { $0.setEnabled(id, enabled) } }

    /// Removes an extension and its data.
    public func uninstall(_ id: String) -> Bool { perform { $0.uninstall(id) } }

    /// Pins or unpins an extension's toolbar action.
    public func setPinned(_ id: String, _ pinned: Bool) -> Bool { perform { $0.setPinned(id, pinned) } }

    /// Opens the options page as a tab next to `tab`.
    public func openOptions(_ id: String, from tab: (any BrowserExtensionTab)? = nil) -> Bool {
        supportsManagement && backend.openOptions(id, from: tab)
    }

    /// Loads an unpacked extension folder into this profile, persistently,
    /// like `chrome://extensions` "Load unpacked".
    public func loadUnpacked(at path: String) -> Bool { perform { $0.loadUnpacked(at: path) } }

    /// Runs a shortcut with `tab` as the active tab.
    ///
    /// `_execute_action` clicks the toolbar action; others dispatch `commands.onCommand`.
    public func run(_ command: BrowserExtensionCommand, in tab: any BrowserExtensionTab) -> Bool {
        if command.isExecuteAction {
            tab.requestExtensionAction(command.extensionID)
            return true
        }
        return backend.runCommand(command, in: tab)
    }

    /// The installed extension with id `text`, else the one whose name matches it case-insensitively.
    public func extensionInfo(matching text: String) -> BrowserExtensionInfo? {
        extensions.first { $0.id == text }
            ?? extensions.first { $0.name.localizedCaseInsensitiveCompare(text) == .orderedSame }
    }

    /// The first shortcut matching `event`, if any.
    public func command(matching event: NSEvent) -> BrowserExtensionCommand? {
        commands.first { $0.matches(event) }
    }

    /// Runs the shortcut `event` is, with `tab` as the active tab.
    ///
    /// Chromium dispatches extension shortcuts from its toolbar, which cmux
    /// hides, and never sees keys while the address or find bar has the
    /// keyboard, so cmux routes them for the focused Chromium page. Call it
    /// for a key down no cmux shortcut took, as cmux Next does
    /// (`KeyRouter.runExtensionShortcut`).
    ///
    /// - Parameters:
    ///   - event: The key down.
    ///   - tab: The focused Chromium page.
    ///   - pageOwnsAllKeys: Browser focus mode is on, so every key is the page's.
    /// - Returns: Whether a shortcut ran.
    public func runShortcut(for event: NSEvent, in tab: any BrowserExtensionTab, pageOwnsAllKeys: Bool = false) -> Bool {
        guard !pageOwnsAllKeys, event.type == .keyDown,
              !event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let command = command(matching: event) else { return false }
        return run(command, in: tab)
    }

    private func perform(_ call: (any BrowserExtensionBackend) -> Bool) -> Bool {
        guard supportsManagement else { return false }
        let accepted = call(backend)
        refresh()
        return accepted
    }
}
