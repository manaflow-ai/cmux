public import CmuxCEF
import Foundation

/// ``CEFExtensionCalls`` over the runtime's loaded shim.
@MainActor
public final class CEFShimExtensionCalls: CEFExtensionCalls {
    private unowned let runtime: CEFRuntime

    /// Creates the calls for `runtime`.
    ///
    /// - Parameter runtime: The process's Chromium runtime.
    public init(runtime: CEFRuntime) {
        self.runtime = runtime
    }

    public var forkAPIVersion: Int32 { runtime.forkAPIVersion }

    public func list(browser: Int32) -> String? {
        guard let shim = runtime.shim, forkAPIVersion >= 3 else { return nil }
        return shim.takeString(shim.extList(browser))
    }

    public func commands(browser: Int32) -> String? {
        guard let shim = runtime.shim, forkAPIVersion >= 3 else { return nil }
        return shim.takeString(shim.extCommands(browser))
    }

    public func actions(browser: Int32, iconPixels: Int32) -> String? {
        guard let shim = runtime.shim, forkAPIVersion >= 1 else { return nil }
        return shim.takeString(shim.extActions(browser, iconPixels))
    }

    public func setEnabled(browser: Int32, id: String, enabled: Bool) -> Bool {
        call { $0.extSetEnabled(browser, id, enabled ? 1 : 0) }
    }

    public func uninstall(browser: Int32, id: String) -> Bool { call { $0.extUninstall(browser, id) } }
    public func reload(browser: Int32, id: String) -> Bool { call { $0.extReload(browser, id) } }

    public func movePinned(browser: Int32, id: String, index: Int) -> Bool {
        call { $0.extMovePinned(browser, id, Int32(clamping: index)) }
    }

    public func setPinned(browser: Int32, id: String, pinned: Bool) -> Bool {
        call { $0.extSetPinned(browser, id, pinned ? 1 : 0) }
    }

    public func openOptions(browser: Int32, id: String) -> Bool { call { $0.extOpenOptions(browser, id) } }
    public func loadUnpacked(browser: Int32, path: String) -> Bool { call { $0.extLoadUnpacked(browser, path) } }

    public func runCommand(browser: Int32, id: String, command: String) -> Bool {
        call { $0.extCommandRun(browser, id, command) }
    }

    public func runAction(browser: Int32, id: String, x: Int32, width: Int32) -> Bool {
        call { $0.extActionRun(browser, id, x, width) }
    }

    public func hidePopup(browser: Int32, id: String) { runtime.shim?.extActionHidePopup(browser, id) }

    public func showActionMenu(browser: Int32, id: String, x: Int32, y: Int32) {
        runtime.shim?.extActionContextMenu(browser, id, x, y)
    }

    public func replyToPrompt(_ promptID: Int32, answer: Int32) -> Bool {
        call { $0.installPromptReply(promptID, answer) }
    }

    public func windowID(browser: Int32) -> Int32 { runtime.shim?.tabWindowID(browser) ?? 0 }

    private func call(_ body: (CEFShimLibrary) -> Int32) -> Bool {
        guard let shim = runtime.shim else { return false }
        return body(shim) == 1
    }
}
