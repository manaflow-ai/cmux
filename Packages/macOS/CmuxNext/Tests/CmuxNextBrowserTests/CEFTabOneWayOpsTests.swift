import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// In host mode a post op returns at once with a stand-in answer, so no CEFTab site may read its
/// result (plans/cmux-next/chrome-parity/p01-process.md, task 022). Each site decides from what
/// cmux already mirrors, as Chrome's UI decides from browser-side state: these tests give every op
/// a spy answer that contradicts the decision, which the tab must ignore.
@MainActor @Suite(.serialized) struct CEFTabOneWayOpsTests {
    /// Chrome's NavigationControllerImpl::CanGoToOffset: the jump goes when the target index is
    /// within the mirrored entries, whatever the op answers.
    @Test func aBackForwardJumpIsDecidedFromTheMirroredEntries() throws {
        let rig = try Rig(forkAPI: 14)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        OneWaySpy.entries = #"{"entries":[{"url":"https://a.test/","title":"A"},{"url":"https://b.test/","title":"B"},{"url":"https://c.test/","title":"C"}],"current":1}"#
        #expect(tab.goToEntry(offset: 1))
        #expect(tab.goToEntry(offset: -1))
        #expect(OneWaySpy.jumps == [1, -1])
        #expect(!tab.goToEntry(offset: 2), "past the last entry")
        #expect(!tab.goToEntry(offset: -2), "before the first entry")
        #expect(!tab.goToEntry(offset: .max), "an offset no Int32 holds")
        #expect(OneWaySpy.jumps == [1, -1], "a jump out of range is never sent")
    }

    @Test func aForkWithoutTheListJumpsNowhere() throws {
        let rig = try Rig(forkAPI: 13)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        OneWaySpy.entries = #"{"entries":[{"url":"https://a.test/","title":"A"},{"url":"https://b.test/","title":"B"}],"current":0}"#
        #expect(!tab.goToEntry(offset: 1))
        #expect(OneWaySpy.jumps.isEmpty)
    }

    /// A person's close whose beforeunload runs (try_close answers 0) leaves the tab to the page:
    /// BEFORE_CLOSE closes it. try_close is async: in process its answer is
    /// the call's own, and 1 (closes now, no question) hands the close back to the caller.
    @Test func aPersonsCloseLeavesTheTabToThePage() throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        OneWaySpy.closeAnswer = 0
        #expect(tab.beginUserClose())
        #expect(OneWaySpy.closes == [7])
        #expect(!tab.isClosed)
        rig.runtime.handle(.beforeClose(browser: 7))
        #expect(tab.isClosed)
    }

    @Test func aCloseWithNoQuestionGoesBackToTheCaller() throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        OneWaySpy.closeAnswer = 1
        #expect(!tab.beginUserClose())
        #expect(OneWaySpy.closes == [7])
    }

    /// Whether the fork has the password fill switch is its mirrored API version, not the answer.
    @Test(arguments: zip([Int32(15), 14], [[Int32(0)], []]))
    func passwordFillGoesOnlyToAForkWithTheSwitch(forkAPI: Int32, sent: [Int32]) throws {
        let rig = try Rig(forkAPI: forkAPI)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        OneWaySpy.fills = []
        tab.markAgentDriven()
        #expect(OneWaySpy.fills == sent)
    }

    /// Chrome's ExtensionActionViewController::ExecuteUserAction: the popup state comes from the
    /// action (enabled, has a popup), and EXTENSION_POPUP_CLOSED ends it.
    @Test func anExtensionPopupIsPredictedFromTheMirroredAction() throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.extensionActions = [
            CEFExtensionAction(id: "popup", name: "Popup", title: "Popup", hasPopup: true),
            CEFExtensionAction(id: "plain", name: "Plain", title: "Plain"),
            CEFExtensionAction(id: "off", name: "Off", title: "Off", isEnabled: false, hasPopup: true),
        ]
        tab.runExtensionAction("plain", anchor: CGRect(x: 10, y: 0, width: 20, height: 20))
        #expect(tab.openExtensionPopup == nil)
        tab.runExtensionAction("off", anchor: CGRect(x: 10, y: 0, width: 20, height: 20))
        #expect(tab.openExtensionPopup == nil)
        tab.runExtensionAction("popup", anchor: CGRect(x: 10, y: 0, width: 20, height: 20))
        #expect(tab.openExtensionPopup == "popup")
        #expect(OneWaySpy.actionRuns == ["plain", "off", "popup"])
        tab.extensionPopupClosed()
        #expect(tab.openExtensionPopup == nil)
    }

    /// The restore goes one-way when the browser exists, and its answer is never read.
    @Test func aPendingRestoreIsSentOnceWithoutReadingItsAnswer() throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let tab = try rig.attachedTab { $0.pendingRestore = "saved-state" }
        #expect(OneWaySpy.restores == ["saved-state"])
        #expect(tab.pendingRestore == nil)
        #expect(OneWaySpy.loads.isEmpty, "the refused answer (-3) is not read")
    }

    /// Every DevTools method goes through the runtime's one send; a refused one freezes nothing.
    @Test func aRefusedDevToolsFreezeReportsNothingChanged() throws {
        let rig = try Rig(forkAPI: 24)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        OneWaySpy.devToolsAnswer = 0
        #expect(!tab.setFrozen(true))
        OneWaySpy.devToolsAnswer = 9
        #expect(tab.setFrozen(true))
        #expect(OneWaySpy.devToolsCalls.filter { $0 == "Page.setWebLifecycleState" }.count == 2)
        #expect(rig.runtime.sendDevTools(7, method: "Page.enable")?.key == CEFDevToolsKey(browser: 7, message: 9))
    }

    // MARK: Rig

    @MainActor final class Rig {
        let runtime: CEFRuntime
        let root: URL

        init(forkAPI: Int32) throws {
            OneWaySpy.reset(forkAPI: forkAPI)
            root = FileManager.default.temporaryDirectory.appending(path: "cef-one-way-ops-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try OneWaySpy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A tab whose browser 7 exists (AFTER_CREATED); `prepare` runs before its creation.
        func attachedTab(_ prepare: (CEFTab) -> Void = { _ in }) throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            prepare(tab)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            try #require(tab.browserID == 7)
            return tab
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The one-way ops a CEFTab sends, recorded, each answering what the tab must not rely on.
private nonisolated enum OneWaySpy {
    nonisolated(unsafe) static var forkAPI: Int32 = 0
    nonisolated(unsafe) static var entries = ""
    nonisolated(unsafe) static var jumps: [Int32] = []
    nonisolated(unsafe) static var closes: [Int32] = []
    nonisolated(unsafe) static var closeAnswer: Int32 = 0
    nonisolated(unsafe) static var fills: [Int32] = []
    nonisolated(unsafe) static var actionRuns: [String] = []
    nonisolated(unsafe) static var restores: [String] = []
    nonisolated(unsafe) static var loads: [String] = []
    nonisolated(unsafe) static var devToolsCalls: [String] = []
    nonisolated(unsafe) static var devToolsAnswer: Int32 = 9

    static func reset(forkAPI api: Int32) {
        forkAPI = api
        entries = ""
        jumps = []
        closes = []
        closeAnswer = 0
        fills = []
        actionRuns = []
        restores = []
        loads = []
        devToolsCalls = []
        devToolsAnswer = 9
    }

    static func text(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { OneWaySpy.forkAPI }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let entries: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { _ in
            OneWaySpy.entries.isEmpty ? nil : strdup(OneWaySpy.entries)
        }
        // Each answer contradicts the tab's decision: the tab must not read it.
        let goToEntry: @convention(c) (Int32, Int32) -> Int32 = { _, offset in OneWaySpy.jumps.append(offset); return 0 }
        let tryClose: @convention(c) (Int32) -> Int32 = { browser in OneWaySpy.closes.append(browser); return OneWaySpy.closeAnswer }
        let passwordFill: @convention(c) (Int32, Int32) -> Int32 = { _, value in OneWaySpy.fills.append(value); return 0 }
        let actionRun: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { _, id, _, _ in
            OneWaySpy.actionRuns.append(OneWaySpy.text(id))
            return 0
        }
        let restore: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { _, state in
            OneWaySpy.restores.append(OneWaySpy.text(state))
            return -3
        }
        let load: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { _, url in OneWaySpy.loads.append(OneWaySpy.text(url)) }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, method, _ in
            OneWaySpy.devToolsCalls.append(OneWaySpy.text(method))
            return OneWaySpy.devToolsAnswer
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_navigation_entries": unsafeBitCast(entries, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_go_to_entry": unsafeBitCast(goToEntry, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_try_close": unsafeBitCast(tryClose, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_set_password_fill": unsafeBitCast(passwordFill, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_ext_action_run": unsafeBitCast(actionRun, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_restore_navigation": unsafeBitCast(restore, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_load_url": unsafeBitCast(load, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
