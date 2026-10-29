import struct CmuxSafeConcurrency.OwnerReference
import Foundation

/// The extension state of one Chromium profile through the fork API. Every
/// call goes through a live browser of the profile (the fork addresses
/// profiles by browser). Management needs fork API v3; older forks list
/// only the enabled extensions that have a toolbar action.
///
/// The same in both backends (plans/cmux-next/chrome-parity/p01-process.md, task 026): the lists
/// are mirror reads, and every management op is an async op in the token form
/// (``CEFRuntime/sendAsync(_:)``), whose answer is Chromium's verdict: the call's result in process,
/// the host's REPLY in host mode. In host mode a change makes the lists pending until that REPLY
/// (the remote shim clears the marks before it hands the REPLY over), so ``snapshot()`` is nil
/// meanwhile and the refresh at the answer reads the host's lists.
final class CEFExtensionBackend: BrowserExtensionBackend {
    /// The runtime, which owns the extension stores this backend serves.
    private let runtimeReference: OwnerReference<CEFRuntime>
    /// The runtime; nil (reported) only once it is gone, and then every call answers that nothing was sent.
    private var runtime: CEFRuntime? { runtimeReference.resolve() }
    private let profileID: BrowserProfileID

    init(runtime: OwnerReference<CEFRuntime>, profile: BrowserProfileID) {
        runtimeReference = runtime
        profileID = profile
    }

    var supportsManagement: Bool { (runtime?.forkAPIVersion ?? 0) >= 3 }
    var supportsPinnedOrder: Bool { (runtime?.forkAPIVersion ?? 0) >= 6 }

    /// Any live Chromium browser of this profile.
    private var anchor: Int32? {
        runtime?.tabsByBrowser.first { $0.value.profileID == profileID }?.key
    }

    /// Nil with no live browser, and while a list has no value (a host-mode mirror a change made
    /// pending, or one the host has not pushed yet): an empty list would read as every extension gone.
    func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])? {
        guard let shim = runtime?.shim, let browser = anchor else { return nil }
        guard supportsManagement else {
            guard let actions = shim.extActions(browser, CEFExtensionAction.iconPixels) else { return nil }
            return (BrowserExtensionInfo.fromActions(CEFExtensionAction.decodeList(actions)), [])
        }
        guard let list = shim.extList(browser), let keys = shim.extCommands(browser) else { return nil }
        return (BrowserExtensionInfo.decodeList(list), BrowserExtensionCommand.decodeList(keys))
    }

    func setEnabled(_ id: String, _ enabled: Bool, answered: @escaping (Bool) -> Void) -> Bool {
        guard let runtime, let browser = anchor else { return false }
        return answer(runtime.sendAsync { $0.extSetEnabled(browser, id, enabled ? 1 : 0) }, label: "extension enable", answered)
    }

    func uninstall(_ id: String, answered: @escaping (Bool) -> Void) -> Bool {
        guard let runtime, let browser = anchor else { return false }
        return answer(runtime.sendAsync { $0.extUninstall(browser, id) }, label: "extension uninstall", answered)
    }

    func movePinned(_ id: String, to index: Int, answered: @escaping (Bool) -> Void) -> Bool {
        guard supportsPinnedOrder, let runtime, let browser = anchor else { return false }
        return answer(runtime.sendAsync { $0.extMovePinned(browser, id, Int32(index)) }, label: "extension move", answered)
    }

    /// Fork API v5 reloads in place; older forks disable, then enable at the disable's answer.
    func reload(_ id: String, answered: @escaping (Bool) -> Void) -> Bool {
        guard let runtime else { return false }
        if runtime.forkAPIVersion >= 5 {
            guard let browser = anchor else { return false }
            return answer(runtime.sendAsync { $0.extReload(browser, id) }, label: "extension reload", answered)
        }
        return setEnabled(id, false) { [weak self] disabled in
            guard disabled, let self, self.setEnabled(id, true, answered: answered) else { return answered(false) }
        }
    }

    func setPinned(_ id: String, _ pinned: Bool, answered: @escaping (Bool) -> Void) -> Bool {
        guard let runtime, let browser = anchor else { return false }
        return answer(runtime.sendAsync { $0.extSetPinned(browser, id, pinned ? 1 : 0) }, label: "extension pin", answered)
    }

    /// Chromium checks the folder and its manifest.
    func loadUnpacked(at path: String, answered: @escaping (Bool) -> Void) -> Bool {
        guard let runtime, let browser = anchor else { return false }
        return answer(runtime.sendAsync { $0.extLoadUnpacked(browser, path) }, label: "load unpacked", answered)
    }

    /// Whether Chromium opened the options page.
    func openOptions(_ id: String, from tab: (any BrowserTab)?, answered: @escaping (Bool) -> Void) -> Bool {
        guard let runtime, let browser = (tab as? CEFTab)?.browserID ?? anchor else { return false }
        return answer(runtime.sendAsync { $0.extOpenOptions(browser, id) }, label: "extension options", answered)
    }

    /// A post with no answer: the store matched the command to a registered shortcut of an enabled
    /// extension in this turn, as Chrome's ExtensionKeybindingRegistry decides from its registered
    /// list (chrome/browser/extensions/extension_keybinding_registry.cc).
    func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool {
        guard let shim = runtime?.shim, let browser = (tab as? CEFTab)?.browserID else { return false }
        _ = shim.extCommandRun(browser, command.extensionID, command.name)
        return true
    }

    /// Whether a management op was sent; `answered` gets Chromium's verdict once (in this turn in
    /// process, in the turn of the host's REPLY in host mode; false for no answer).
    private func answer(_ sent: CEFShimAnswer<Int32>, label: String, _ answered: @escaping (Bool) -> Void) -> Bool {
        guard let runtime else { return false }
        if case .unsent = sent { return false }
        runtime.whenAnswered(sent, label: label) { answered($0 == 1) }
        return true
    }
}
