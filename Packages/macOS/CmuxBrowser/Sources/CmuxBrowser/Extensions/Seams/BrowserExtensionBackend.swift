/// Where a ``BrowserExtensionStore`` reads and changes extension state.
///
/// The Chromium engine implements it per profile through the cmux CEF fork;
/// tests and demos pass a mock. Every mutating call returns whether Chromium
/// accepted it.
@MainActor
public protocol BrowserExtensionBackend: AnyObject {
    /// True when enable/disable, remove, pin, options and load unpacked are available (fork API v3).
    var supportsManagement: Bool { get }
    /// True when pinned extensions can be reordered (fork API v6).
    var supportsPinnedOrder: Bool { get }
    /// The installed extensions and shortcuts, or nil while no browser of the
    /// profile is live (the store then keeps its last lists).
    func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])?
    /// Enables or disables an extension.
    func setEnabled(_ id: String, _ enabled: Bool) -> Bool
    /// Removes an extension and its data.
    func uninstall(_ id: String) -> Bool
    /// Reloads an extension, also a terminated (crashed) one.
    func reload(_ id: String) -> Bool
    /// Moves a pinned extension to `index` among the pinned ones.
    func movePinned(_ id: String, to index: Int) -> Bool
    /// Pins or unpins an extension's toolbar action.
    func setPinned(_ id: String, _ pinned: Bool) -> Bool
    /// Opens the options page as a tab next to `tab`.
    func openOptions(_ id: String, from tab: (any BrowserExtensionTab)?) -> Bool
    /// Loads an unpacked extension folder into the profile, persistently.
    func loadUnpacked(at path: String) -> Bool
    /// Dispatches `commands.onCommand` (not `_execute_action`) in `tab`.
    func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserExtensionTab) -> Bool
}

extension BrowserExtensionBackend {
    /// Backends without an order API keep Chromium's pinned order.
    public var supportsPinnedOrder: Bool { false }

    /// Backends without an order API refuse moves.
    public func movePinned(_ id: String, to index: Int) -> Bool { false }
}
