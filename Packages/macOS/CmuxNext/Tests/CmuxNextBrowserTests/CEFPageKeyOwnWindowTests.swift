@testable import CmuxNextBrowser
import Foundation
import Testing

/// The warm start keeps only the default profile's spare window: a cmux page's key (the in-memory pages
/// profile) never takes it and builds its own window. This is the shipped default (the
/// `pagesSpareWindow` feature off) and pins it for that feature's removal (prove-or-remove 11-04, row
/// p13-04). Against a spy shim that counts `cmux_shim_create_window`; each test has its own runtime.
@MainActor @Suite(.serialized) struct CEFPageKeyOwnWindowTests {
    private let pages = BrowserProfileID(rawValue: UUID())

    @Test func onlyTheBrowserSpareIsWanted() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.wantedKinds == [.browser])
        #expect(runtime.spareWindow.prepareNext(runtime: runtime))
        #expect(runtime.spareWindow.state(of: .browser) == .creating)
        #expect(runtime.spareWindow.untakenCount == 1)
    }

    @Test func aPageKeyBuildsItsOwnWindowBesideTheBrowserSpare() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        let spare = try #require(runtime.spareWindow.host(of: .browser))
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: 10, request: request, window: 10))

        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: "cmux-page-test"), profile: pages, offTheRecord: true)
        #expect(runtime.spareWindow.kind(for: key) == nil)
        let host = runtime.host(for: key)
        #expect(host !== spare, "a page's key took the browser spare")
        let tab = CEFTab(id: .random(), profile: pages, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(PageKeySpy.createWindowCalls == 2, "the page's own window")
        #expect(runtime.spareWindow.host(of: .browser) === spare, "the browser spare stays untaken")
    }

    /// A runtime that outlives the test: a window that came up shows itself at the end of the turn.
    private static func spyRuntime() throws -> (CEFRuntime, URL) {
        PageKeySpy.createWindowCalls = 0
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-page-key-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime.spy(shim: try PageKeySpy.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }
}

/// Stand-in shim: `cmux_shim_create_window` counts its calls and reports the browser started; every other
/// function does nothing and returns 0.
private nonisolated enum PageKeySpy {
    nonisolated(unsafe) static var createWindowCalls = 0

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            PageKeySpy.createWindowCalls += 1
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
