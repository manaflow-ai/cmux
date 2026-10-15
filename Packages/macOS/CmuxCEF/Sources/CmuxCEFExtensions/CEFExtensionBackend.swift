public import CmuxBrowser
public import Foundation

/// The extension state of one Chromium profile through the fork API.
///
/// Every call goes through a live browser of the profile (`anchor`).
/// Management needs fork API v3; older forks list only the enabled
/// extensions that have a toolbar action.
@MainActor
public final class CEFExtensionBackend: BrowserExtensionBackend {
    private let calls: any CEFExtensionCalls
    private let anchor: @MainActor () -> Int32?

    /// Creates a backend.
    ///
    /// - Parameters:
    ///   - calls: The fork's extension calls.
    ///   - anchor: Any live Chromium browser id of the profile, or nil while none is open.
    public init(calls: any CEFExtensionCalls, anchor: @escaping @MainActor () -> Int32?) {
        self.calls = calls
        self.anchor = anchor
    }

    public var supportsManagement: Bool { calls.forkAPIVersion >= 3 }
    public var supportsPinnedOrder: Bool { calls.forkAPIVersion >= 6 }

    public func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])? {
        guard let browser = anchor() else { return nil }
        guard supportsManagement else {
            guard let json = calls.actions(browser: browser, iconPixels: CEFExtensionPageSupport.iconPixels) else {
                return nil
            }
            return (BrowserExtensionInfo.fromActions(BrowserExtensionAction.decodeList(json)), [])
        }
        guard let list = calls.list(browser: browser) else { return nil }
        let commands = calls.commands(browser: browser) ?? "[]"
        return (BrowserExtensionInfo.decodeList(list), BrowserExtensionCommand.decodeList(commands))
    }

    public func setEnabled(_ id: String, _ enabled: Bool) -> Bool {
        withAnchor { calls.setEnabled(browser: $0, id: id, enabled: enabled) }
    }

    public func uninstall(_ id: String) -> Bool { withAnchor { calls.uninstall(browser: $0, id: id) } }

    /// Fork API v5 reloads in place; older forks disable and enable again
    /// (Chromium moves a terminated extension to the disabled set and loads it on enable).
    public func reload(_ id: String) -> Bool {
        if calls.forkAPIVersion >= 5 { return withAnchor { calls.reload(browser: $0, id: id) } }
        return setEnabled(id, false) && setEnabled(id, true)
    }

    public func movePinned(_ id: String, to index: Int) -> Bool {
        supportsPinnedOrder && withAnchor { calls.movePinned(browser: $0, id: id, index: index) }
    }

    public func setPinned(_ id: String, _ pinned: Bool) -> Bool {
        withAnchor { calls.setPinned(browser: $0, id: id, pinned: pinned) }
    }

    public func openOptions(_ id: String, from tab: (any BrowserExtensionTab)?) -> Bool {
        guard let browser = (tab as? any CEFExtensionTab)?.cefBrowserID ?? anchor() else { return false }
        return calls.openOptions(browser: browser, id: id)
    }

    public func loadUnpacked(at path: String) -> Bool { withAnchor { calls.loadUnpacked(browser: $0, path: path) } }

    public func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserExtensionTab) -> Bool {
        guard let browser = (tab as? any CEFExtensionTab)?.cefBrowserID else { return false }
        return calls.runCommand(browser: browser, id: command.extensionID, command: command.name)
    }

    private func withAnchor(_ body: (Int32) -> Bool) -> Bool {
        guard let browser = anchor() else { return false }
        return body(browser)
    }
}
