@testable import CmuxNextBrowser
import Foundation
import Testing

/// ``CEFPagePush`` and ``CEFForkFeatures/pagePush``: a push reaches the shim's
/// `cmux_shim_tab_page_push` only with fork API 43 and the export, and never before the browser exists.
@MainActor
struct CEFPagePushTests {
    @Test func theGateNeedsTheForkAPIAndTheExport() {
        #expect(CEFForkFeatures(forkAPIVersion: CEFForkFeatures.pagePushForkAPI, shimHasRendererPaths: true, shimHasPagePush: true).pagePush)
        #expect(!CEFForkFeatures(forkAPIVersion: CEFForkFeatures.pagePushForkAPI - 1, shimHasRendererPaths: true, shimHasPagePush: true).pagePush)
        #expect(!CEFForkFeatures(forkAPIVersion: CEFForkFeatures.pagePushForkAPI, shimHasRendererPaths: true, shimHasPagePush: false).pagePush)
    }

    @Test func aPushGoesToTheTabsBrowserInOrder() throws {
        let rig = try PushRig(forkAPI: CEFForkFeatures.pagePushForkAPI)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let push = CEFPagePush(tab: tab)
        #expect(push.isAvailable)
        push.send("[1]")
        push.send(#"{"r":2,"v":null}"#)
        #expect(PushSpy.pushes == ["7 [1]", #"7 {"r":2,"v":null}"#])
    }

    @Test func noPushOnAnOlderForkOrWithoutABrowser() throws {
        let older = try PushRig(forkAPI: CEFForkFeatures.pagePushForkAPI - 1)
        defer { older.close() }
        let tab = try older.attachedTab()
        #expect(!CEFPagePush(tab: tab).isAvailable)
        CEFPagePush(tab: tab).send("[1]")
        #expect(PushSpy.pushes.isEmpty)

        let rig = try PushRig(forkAPI: CEFForkFeatures.pagePushForkAPI)
        defer { rig.close() }
        let unborn = rig.makeTab()
        CEFPagePush(tab: unborn).send("[1]")
        let closed = try rig.attachedTab()
        closed.close()
        CEFPagePush(tab: closed).send("[1]")
        #expect(PushSpy.pushes.isEmpty)
    }

    // MARK: Rig

    @MainActor final class PushRig {
        let runtime: CEFRuntime
        let root: URL
        private var host: CEFPaneHost?

        init(forkAPI: Int32) throws {
            PushSpy.reset(forkAPI: forkAPI)
            root = FileManager.default.temporaryDirectory.appending(path: "cef-page-push-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try PushSpy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A tab with no browser yet.
        func makeTab() -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            self.host = host
            return CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        }

        /// A tab whose browser 7 exists (AFTER_CREATED).
        func attachedTab() throws -> CEFTab {
            let tab = makeTab()
            let host = try #require(host)
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

/// The shim's page pushes, in order; every other function does nothing.
private nonisolated enum PushSpy {
    nonisolated(unsafe) static var forkAPI: Int32 = 39
    nonisolated(unsafe) static var pushes: [String] = []

    static func reset(forkAPI api: Int32) {
        forkAPI = api
        pushes = []
    }

    static func library() throws -> CEFShimLibrary {
        try CEFShimLibrary.resolving(symbol)
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let version: @convention(c) () -> Int32 = { PushSpy.forkAPI }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let push: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { browser, text in
            PushSpy.pushes.append("\(browser) \(text.map { String(cString: $0) } ?? "")")
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_page_push": unsafeBitCast(push, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
