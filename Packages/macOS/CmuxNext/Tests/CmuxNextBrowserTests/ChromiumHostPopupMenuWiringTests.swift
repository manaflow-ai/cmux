import AppKit
@testable import CmuxNextBrowser
import Testing

/// How host mode turns `<select>` popups as cmux menus on (feature
/// `chromiumHostPopupMenus`): the source's choice reaches the host start, the start asks the host for
/// POPUP_MENU only with the feature on and a fork at API 31, a POPUP_MENU with no menus to show it is
/// answered -1, and the host's end closes an open menu with no answer.
@MainActor @Suite(.serialized) struct ChromiumHostPopupMenuWiringTests {
    private static func idleRuntime() -> CEFRuntime {
        CEFRuntime(storage: CEFProfileStorage(root: FileManager.default.temporaryDirectory
                .appending(path: "cef-popup-menus-\(UUID().uuidString)", directoryHint: .isDirectory)))
    }

    @Test func theSourcesChoiceReachesTheHostStart() {
        #expect(!CEFRuntimeSource(layout: nil).drawsHostPopupMenus)
        let on = Self.idleRuntime()
        on.adopt(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), hostSupervisor: PopupEndingSupervisor(), hostPopupMenus: true)
        #expect(on.hostStart?.drawsPopupMenus == true)
        let off = Self.idleRuntime()
        off.adopt(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), hostSupervisor: PopupEndingSupervisor())
        #expect(off.hostStart?.drawsPopupMenus == false)
    }

    /// The feature on and a fork at API 31: popups come as POPUP_MENU, and cmux shows them.
    @Test func theFeatureTurnsTheHostsPopupsOn() throws {
        PopupSpy.reset()
        let runtime = Self.idleRuntime()
        runtime.hostStart = CEFHostStart(supervisor: PopupEndingSupervisor(), drawsPopupMenus: true)
        runtime.showHostNativeUI(try CEFShimLibrary.resolving(PopupSpy.symbol), forkAPIVersion: 31)
        #expect(runtime.hostStart?.popupMenus != nil)
        #expect(PopupSpy.enabled == [1])
    }

    /// Off, in process, or with an older fork: Chromium keeps its own menu, and cmux asks for nothing.
    @Test func nothingChangesWithoutTheFeatureOrTheFork() throws {
        PopupSpy.reset()
        let shim = try CEFShimLibrary.resolving(PopupSpy.symbol)
        let off = Self.idleRuntime()
        off.hostStart = CEFHostStart(supervisor: PopupEndingSupervisor())
        off.showHostPopupMenus(shim, forkAPIVersion: 31)
        let inProcess = Self.idleRuntime()
        inProcess.showHostPopupMenus(shim, forkAPIVersion: 31)
        let oldFork = Self.idleRuntime()
        oldFork.hostStart = CEFHostStart(supervisor: PopupEndingSupervisor(), drawsPopupMenus: true)
        oldFork.showHostPopupMenus(shim, forkAPIVersion: 30)
        #expect(off.hostStart?.popupMenus == nil && inProcess.hostStart == nil && oldFork.hostStart?.popupMenus == nil)
        #expect(PopupSpy.enabled.isEmpty)
    }

    /// A POPUP_MENU with no cmux menus to show it is answered -1 in its turn, so the page never waits.
    @Test func aPopupWithNoMenusIsCancelled() throws {
        PopupSpy.reset()
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(PopupSpy.symbol), storage: CEFProfileStorage(
            root: FileManager.default.temporaryDirectory.appending(path: "cef-popup-menus-\(UUID().uuidString)", directoryHint: .isDirectory)))
        runtime.dispatch(.popupMenu(browser: 7, token: 1 << 40, popup: nil))
        #expect(PopupSpy.replies == [[7, 1 << 40, -1]])
        // A hide with nothing open does nothing.
        runtime.dispatch(.popupMenuHidden(browser: 7, token: 1 << 40))
        #expect(PopupSpy.replies.count == 1)
    }

    /// A DevTools browser is no tab: its popups show over its tab's DevTools page view while that
    /// DevTools is open and shown (in its window, or docked in a pane that shows the tab).
    @Test func aDevToolsBrowsersPopupsShowOverItsDevToolsPage() {
        let runtime = Self.idleRuntime()
        // The pane and the tab read the runtime through unowned references, also as they go.
        _ = Unmanaged.passRetained(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        runtime.tabsByBrowser[7] = tab
        let controller = tab.devToolsController
        let page = controller.hostedPage(for: tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        content.addSubview(page)

        #expect(runtime.popupMenuView(of: 9) == nil, "no DevTools is open")
        controller.devToolsBrowserID = 9
        tab.devTools = BrowserDevToolsState(isOpen: true, dock: .window)
        #expect(runtime.popupMenuView(of: 9) === page)
        #expect(runtime.popupMenuView(of: 8) == nil, "another browser's DevTools page")
        tab.devTools = BrowserDevToolsState(isOpen: true, dock: .bottom)
        #expect(runtime.popupMenuView(of: 9) == nil, "docked in a pane that does not show the tab")
        tab.devTools = BrowserDevToolsState(isOpen: true, dock: .window)
        page.removeFromSuperview()
        #expect(runtime.popupMenuView(of: 9) == nil, "a DevTools page in no window shows no popup")

        content.addSubview(page)
        let wire = PopupRecordingWire()
        var seams = ChromiumHostPopupMenus.Seams()
        seams.later = { $0() }
        var shownIn: NSView?
        seams.track = { run in
            shownIn = run.view
            return 1
        }
        let menus = ChromiumHostPopupMenus(wire: wire, pageView: { [weak runtime] in runtime?.popupMenuView(of: $0) }, seams: seams)
        menus.show(browser: 9, token: 3, popup: ChromiumHostPopupMenu(bounds: CGRect(x: 0, y: 0, width: 100, height: 20),
                                                                      items: [.init(label: "one"), .init(label: "two")]))
        #expect(shownIn === page)
        #expect(wire.replies.map { [Int64($0.0), $0.1, Int64($0.2)] } == [[9, 3, 1]])
        withExtendedLifetime(window) {}
    }

    /// The shim's wire sends the browser, the 64-bit token and the index as they are.
    @Test func theShimWireSendsTheReply() throws {
        PopupSpy.reset()
        let wire = CEFShimPopupMenuWire(ops: try CEFShimLibrary.resolving(PopupSpy.symbol).popupMenus)
        wire.reply(browser: 9, token: 9_007_199_254_740_993, index: 3)
        #expect(PopupSpy.replies == [[9, 9_007_199_254_740_993, 3]])
    }

    /// A host that ends sends no POPUP_MENU_HIDE: the supervisor's end closes the menu with no answer.
    @Test func theHostsEndClosesTheMenu() {
        _ = NSApplication.shared
        let supervisor = PopupEndingSupervisor()
        let start = CEFHostStart(supervisor: supervisor, drawsPopupMenus: true)
        let wire = PopupRecordingWire()
        var seams = ChromiumHostPopupMenus.Seams()
        seams.later = { $0() }
        seams.track = { _ in
            supervisor.end()
            return 0
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = view
        let menus = ChromiumHostPopupMenus(wire: wire, pageView: { _ in view }, seams: seams)
        start.popupMenus = menus
        menus.show(browser: 7, token: 1, popup: ChromiumHostPopupMenu(bounds: CGRect(x: 0, y: 0, width: 100, height: 20),
                                                                      items: [.init(label: "one")]))
        #expect(wire.replies.isEmpty)
        #expect(menus.presentedMenu == nil)
        withExtendedLifetime(window) {}
    }
}

@MainActor
private final class PopupRecordingWire: ChromiumHostPopupMenuWire {
    var replies: [(Int32, Int64, Int32)] = []
    func reply(browser: Int32, token: Int64, index: Int32) { replies.append((browser, token, index)) }
}

/// A supervisor that is never asked for a wire; ``end()`` reports the host's end as a real one would.
@MainActor
private final class PopupEndingSupervisor: ChromiumHostSupervising {
    private var ended: [@MainActor () -> Void] = []

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not used in ChromiumHostPopupMenuWiringTests")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {
        self.ended.append(ended)
    }

    func end() {
        for handler in ended { handler() }
    }
}

/// The shim with the popup ops recording their arguments; every other function does nothing and returns 0.
private nonisolated enum PopupSpy {
    nonisolated(unsafe) static var enabled: [Int32] = []
    nonisolated(unsafe) static var replies: [[Int64]] = []

    static func reset() {
        enabled = []
        replies = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let setEnabled: @convention(c) (Int32) -> Void = { PopupSpy.enabled.append($0) }
        let reply: @convention(c) (Int32, Int64, Int32) -> Void = { browser, token, index in
            PopupSpy.replies.append([Int64(browser), token, Int64(index)])
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_set_popup_menus": unsafeBitCast(setEnabled, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_popup_menu_reply": unsafeBitCast(reply, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
