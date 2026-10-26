import Foundation

/// The extension state of one Chromium profile through the fork API. Every
/// call goes through a live browser of the profile (the fork addresses
/// profiles by browser). Management needs fork API v3; older forks list
/// only the enabled extensions that have a toolbar action.
///
/// The same in both backends (plans/cmux-next/chrome-parity/p01-process.md, task 026): the lists
/// are mirror reads, a change is a post that Chromium's extension events confirm, and the options
/// page and load unpacked are async ops whose answer comes in the token form
/// (``CEFRuntime/sendAsync(_:)``). In host mode a post makes the lists pending until the host
/// applied it, so ``snapshot()`` is nil then and the store keeps what it shows.
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

    /// Nil with no live browser, and while a list has no value (a host-mode mirror a change made
    /// pending, or one the host has not pushed yet): an empty list would read as every extension gone.
    func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])? {
        guard let shim = runtime.shim, let browser = anchor else { return nil }
        guard supportsManagement else {
            guard let actions = shim.takeString(shim.extActions(browser, CEFExtensionAction.iconPixels)) else { return nil }
            return (BrowserExtensionInfo.fromActions(CEFExtensionAction.decodeList(actions)), [])
        }
        guard let list = shim.takeString(shim.extList(browser)), let keys = shim.takeString(shim.extCommands(browser)) else { return nil }
        return (BrowserExtensionInfo.decodeList(list), BrowserExtensionCommand.decodeList(keys))
    }

    func setEnabled(_ id: String, _ enabled: Bool) -> Bool { post { _ = $0.extSetEnabled($1, id, enabled ? 1 : 0) } }
    func uninstall(_ id: String) -> Bool { post { _ = $0.extUninstall($1, id) } }

    func movePinned(_ id: String, to index: Int) -> Bool {
        supportsPinnedOrder && post { _ = $0.extMovePinned($1, id, Int32(index)) }
    }

    /// Fork API v5 reloads in place; older forks disable and enable again.
    func reload(_ id: String) -> Bool {
        if runtime.forkAPIVersion >= 5 { return post { _ = $0.extReload($1, id) } }
        return setEnabled(id, false) && setEnabled(id, true)
    }
    func setPinned(_ id: String, _ pinned: Bool) -> Bool { post { _ = $0.extSetPinned($1, id, pinned ? 1 : 0) } }

    /// Chromium checks the folder and its manifest: the answer in process, true once sent in host
    /// mode, where a refusal in the host's REPLY is logged.
    func loadUnpacked(at path: String) -> Bool {
        guard let browser = anchor else { return false }
        return accepted(runtime.sendAsync { $0.extLoadUnpacked(browser, path) }, label: "load unpacked")
    }

    /// Whether Chromium opened the options page: the answer in process, true once sent in host mode,
    /// where a refusal in the host's REPLY is logged.
    func openOptions(_ id: String, from tab: (any BrowserTab)?) -> Bool {
        guard let browser = (tab as? CEFTab)?.browserID ?? anchor else { return false }
        return accepted(runtime.sendAsync { $0.extOpenOptions(browser, id) }, label: "extension options")
    }

    /// A post with no answer: the store matched the command to an enabled extension in this turn, as
    /// Chrome's ExtensionKeybindingRegistry decides from its registered list
    /// (chrome/browser/extensions/extension_keybinding_registry.cc).
    func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool {
        guard let shim = runtime.shim, let browser = (tab as? CEFTab)?.browserID else { return false }
        _ = shim.extCommandRun(browser, command.extensionID, command.name)
        return true
    }

    /// Sends a change to the anchor browser; false when none is live. The result is not read: the
    /// remote shim's is only "sent", and Chromium's extension event reports the change.
    private func post(_ body: (CEFShimLibrary, Int32) -> Void) -> Bool {
        guard let shim = runtime.shim, let browser = anchor else { return false }
        body(shim, browser)
        return true
    }

    /// The answer of a management op, in this turn where one exists (in process); else whether it was
    /// sent, with the host's refusal logged when its REPLY comes.
    private func accepted(_ sent: CEFShimAnswer<Int32>, label: String) -> Bool {
        switch sent {
        case .now(let result):
            return result == 1
        case .unsent:
            return false
        case .later:
            runtime.whenAnswered(sent, label: label) { [logger = runtime.logger] result in
                guard result != 1 else { return }
                let answer = result.map { "\($0)" } ?? "no answer"
                logger.notice("Chromium Host \(label, privacy: .public) refused (\(answer, privacy: .public))")
            }
            return true
        }
    }
}
