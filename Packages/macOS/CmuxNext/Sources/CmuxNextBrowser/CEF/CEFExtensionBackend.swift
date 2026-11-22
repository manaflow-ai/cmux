import Foundation

/// The extension state of one Chromium profile through the fork API. Every
/// call goes through a live browser of the profile (the fork addresses
/// profiles by browser). Management needs fork API v3; older forks list
/// only the enabled extensions that have a toolbar action.
final class CEFExtensionBackend: BrowserExtensionBackend {
    private unowned let runtime: CEFRuntime
    private let profileID: BrowserProfileID

    init(runtime: CEFRuntime, profile: BrowserProfileID) {
        self.runtime = runtime
        profileID = profile
    }

    var supportsManagement: Bool { runtime.forkAPIVersion >= 3 }
    var supportsPinnedOrder: Bool { runtime.forkAPIVersion >= 6 }

    /// Any live Chromium browser of this profile.
    private var anchor: Int32? {
        runtime.tabsByBrowser.first { $0.value.profileID == profileID }?.key
    }

    func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])? {
        guard let shim = runtime.shim, let browser = anchor else { return nil }
        guard supportsManagement else {
            let actions = CEFExtensionAction.decodeList(shim.takeString(shim.extActions(browser, CEFExtensionAction.iconPixels)) ?? "[]")
            return (BrowserExtensionInfo.fromActions(actions), [])
        }
        let list = BrowserExtensionInfo.decodeList(shim.takeString(shim.extList(browser)) ?? "[]")
        let keys = BrowserExtensionCommand.decodeList(shim.takeString(shim.extCommands(browser)) ?? "[]")
        return (list, keys)
    }

    func setEnabled(_ id: String, _ enabled: Bool) -> Bool { call { $0.extSetEnabled($1, id, enabled ? 1 : 0) } }
    func uninstall(_ id: String) -> Bool { call { $0.extUninstall($1, id) } }

    func movePinned(_ id: String, to index: Int) -> Bool {
        supportsPinnedOrder && call { $0.extMovePinned($1, id, Int32(index)) }
    }

    /// Fork API v5 reloads in place; older forks disable and enable again.
    func reload(_ id: String) -> Bool {
        if runtime.forkAPIVersion >= 5 { return call { $0.extReload($1, id) } }
        return setEnabled(id, false) && setEnabled(id, true)
    }
    func setPinned(_ id: String, _ pinned: Bool) -> Bool { call { $0.extSetPinned($1, id, pinned ? 1 : 0) } }
    func loadUnpacked(at path: String) -> Bool { call { $0.extLoadUnpacked($1, path) } }

    func openOptions(_ id: String, from tab: (any BrowserTab)?) -> Bool {
        guard let shim = runtime.shim, let browser = (tab as? CEFTab)?.browserID ?? anchor else { return false }
        return shim.extOpenOptions(browser, id) == 1
    }

    func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool {
        guard let shim = runtime.shim, let browser = (tab as? CEFTab)?.browserID else { return false }
        return shim.extCommandRun(browser, command.extensionID, command.name) == 1
    }

    private func call(_ body: (CEFShimLibrary, Int32) -> Int32) -> Bool {
        guard let shim = runtime.shim, let browser = anchor else { return false }
        return body(shim, browser) == 1
    }
}
