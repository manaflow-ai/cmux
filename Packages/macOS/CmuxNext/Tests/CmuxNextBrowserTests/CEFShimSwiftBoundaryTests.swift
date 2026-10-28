@testable import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// Every C string, buffer and out-parameter of the shim crosses in ``CEFShimLibrary``
/// (Chromium keeps its `UNSAFE_BUFFERS()` at the boundary, docs/unsafe_buffers.md), so callers pass and get
/// Swift values. Against a spy shim whose C functions record what they got.
@Suite(.serialized) struct CEFShimSwiftBoundaryTests {
    @Test func aStringArgumentArrivesAsItsNulTerminatedTextAndNilAsNull() throws {
        BoundarySpy.reset()
        let shim = try CEFShimLibrary.resolving(BoundarySpy.symbol)
        shim.loadURL(7, "https://example.com/é")
        shim.loadURL(8, nil)
        #expect(BoundarySpy.loaded == [7: "https://example.com/é", 8: "<NULL>"])
    }

    @Test func aStringTheShimAllocatedIsCopiedAndFreedOnceWithItsOwnFree() throws {
        BoundarySpy.reset()
        let shim = try CEFShimLibrary.resolving(BoundarySpy.symbol)
        #expect(shim.tabNavigationState(5) == "state-5")
        #expect(BoundarySpy.freed == 1 && BoundarySpy.freedOwned == 0, "cmux_shim_free frees a fork string")
        #expect(shim.sslStatus(5) == "ssl-5")
        #expect(BoundarySpy.freed == 1 && BoundarySpy.freedOwned == 1, "cmux_shim_free_owned frees a shim-owned string")
        #expect(shim.tabNavigationState(0) == nil, "NULL is nil, and nothing is freed")
        #expect(BoundarySpy.freed == 1)
    }

    @Test func rendererIDsNeverReadPastWhatTheShimWroteOrTheRoomItHad() throws {
        BoundarySpy.reset()
        let shim = try CEFShimLibrary.resolving(BoundarySpy.symbol)
        BoundarySpy.clientIDCount = 3
        #expect(shim.rendererClientIDs(1, 32) == [100, 101, 102])
        BoundarySpy.clientIDCount = 40  // a shim that answers more than the room it was given
        #expect(shim.rendererClientIDs(1, 4) == [100, 101, 102, 103])
        BoundarySpy.clientIDCount = -1
        #expect(shim.rendererClientIDs(1, 32).isEmpty)
        #expect(shim.rendererClientIDs(1, 0).isEmpty, "no room reads nothing")
    }

    @Test func boundsComeBackAsAValueWithTheCallsResult() throws {
        BoundarySpy.reset()
        let shim = try CEFShimLibrary.resolving(BoundarySpy.symbol)
        #expect(shim.popupWindowBounds(9) == CEFShimBounds(result: 1, x: 9, y: 10, width: 11, height: 12))
        #expect(shim.devToolsInspectedBounds(0) == CEFShimBounds(), "a refusal writes nothing and reads as zeros")
    }

    @Test func passwordIdsGoAsOneArrayOfCStrings() throws {
        BoundarySpy.reset()
        let shim = try CEFShimLibrary.resolving(BoundarySpy.symbol)
        #expect(shim.passwordRemove("/profile", ["a", "bé", ""], 4) == 3)
        #expect(BoundarySpy.removed == ["/profile", "a", "bé", ""])
        #expect(shim.passwordRemove("/profile", [], 5) == 0)
    }

    @Test func aFrameworkLoadReportsTheShimsMessageOnlyWhenItFails() throws {
        BoundarySpy.reset()
        let shim = try CEFShimLibrary.resolving(BoundarySpy.symbol)
        #expect(shim.loadFramework("/ok") == nil)
        #expect(shim.loadFramework("/missing") == "no framework at /missing")
    }

    @Test func theParentViewArgumentIsTheTokenOrTheViewsAddress() throws {
        BoundarySpy.reset()
        let shim = try CEFShimLibrary.resolving(BoundarySpy.symbol)
        _ = shim.popupWindowAttach(3, CEFParentView(token: 0x42), 10, 10)
        _ = shim.popupWindowAttach(4, nil, 10, 10)
        #expect(BoundarySpy.parents == [3: 0x42, 4: 0])
    }

    @Test func switchArgumentsAreANullTerminatedArgv() {
        let arguments = CEFSwitchArguments(["--a", "--b=é"])
        #expect(arguments.argv.count == 3)
        #expect(unsafe arguments.argv.last.map { unsafe $0 == nil } == true, "argv ends with NULL")
        // SAFETY: the first two entries are live NUL-terminated copies while `arguments` lives.
        let texts = unsafe arguments.argv.prefix(2).map { unsafe $0.map(String.init(cString:)) }
        #expect(texts == ["--a", "--b=é"])
    }

    @Test func procArgsReadArgcLittleEndianAndStopAtIt() {
        // argc 2, exec path, NUL padding, then three strings (the third is the environment).
        let buffer: [UInt8] = [2, 0, 0, 0] + Array("/bin/helper".utf8) + [0, 0, 0]
            + Array("--type=renderer".utf8) + [0] + Array("--extension-process".utf8) + [0] + Array("HOME=/".utf8) + [0]
        #expect(CEFHelperIdentity.parseProcArgs(buffer) == ["--type=renderer", "--extension-process"])
        #expect(CEFHelperIdentity.parseProcArgs([0xff, 0xff, 0xff, 0xff, 0x41, 0]).isEmpty, "a negative argc reads nothing")
    }

    @Test func littleEndianBytesMatchTheWireOrder() {
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(UInt32(0x0403_0201))
        bytes.appendLittleEndian(Int16(-2))
        bytes.appendLittleEndian(UInt64(0x0807_0605_0403_0201))
        #expect(bytes == [1, 2, 3, 4, 0xfe, 0xff, 1, 2, 3, 4, 5, 6, 7, 8])
    }
}

/// A fake shim: the string, buffer and out-parameter exports record what they got; every other export does
/// nothing and answers 0 (NULL).
private nonisolated enum BoundarySpy {
    // crash-allow: test-only spy state, written and read on the serialized suite's one thread at a time.
    nonisolated(unsafe) static var loaded: [Int32: String] = [:]
    // crash-allow: as above.
    nonisolated(unsafe) static var freed = 0
    // crash-allow: as above.
    nonisolated(unsafe) static var freedOwned = 0
    // crash-allow: as above.
    nonisolated(unsafe) static var clientIDCount: Int32 = 0
    // crash-allow: as above.
    nonisolated(unsafe) static var removed: [String] = []
    // crash-allow: as above.
    nonisolated(unsafe) static var parents: [Int32: UInt] = [:]

    static func reset() {
        loaded = [:]
        freed = 0
        freedOwned = 0
        clientIDCount = 0
        removed = []
        parents = [:]
    }

    // SAFETY (every `unsafe` below): each closure is a C function of its export's type in cmux_cef_shim.h, and it
    // reads or writes its pointer arguments only within the bounds that export's contract gives.
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let loadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { browser, url in
            BoundarySpy.loaded[browser] = unsafe url.map(String.init(cString:)) ?? "<NULL>"
        }
        let state: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { browser in
            browser == 0 ? nil : unsafe strdup("state-\(browser)")
        }
        let ssl: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { browser in unsafe strdup("ssl-\(browser)") }
        let free: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { pointer in
            BoundarySpy.freed += 1
            unsafe Darwin.free(pointer)
        }
        let freeOwned: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { pointer in
            BoundarySpy.freedOwned += 1
            unsafe Darwin.free(pointer)
        }
        let clientIDs: @convention(c) (Int32, UnsafeMutablePointer<Int32>?, Int32) -> Int32 = { _, out, room in
            let count = BoundarySpy.clientIDCount
            for index in 0..<max(0, min(count, room)) { unsafe out?[Int(index)] = 100 + index }
            return count
        }
        let bounds: @convention(c) (Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                    UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32 = { id, x, y, width, height in
            guard id != 0 else { return 0 }
            unsafe x?.pointee = id
            unsafe y?.pointee = id + 1
            unsafe width?.pointee = id + 2
            unsafe height?.pointee = id + 3
            return 1
        }
        let remove: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, Int32, Int32) -> Int32 = { path, ids, count, _ in
            BoundarySpy.removed = [unsafe path.map(String.init(cString:)) ?? "<NULL>"]
                + (0..<Int(count)).map { unsafe ids?[$0].map(String.init(cString:)) ?? "<NULL>" }
            return count
        }
        let load: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32 = { path, message, capacity in
            let text = unsafe path.map(String.init(cString:)) ?? ""
            guard text != "/ok" else { return 1 }
            let reason = Array("no framework at \(text)".utf8CString.prefix(capacity - 1)) + [0]
            for (index, byte) in reason.enumerated() { unsafe message?[index] = byte }
            return 0
        }
        let attach: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32) -> Int32 = { window, parent, _, _ in
            BoundarySpy.parents[window] = unsafe UInt(bitPattern: parent)
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_load_url": unsafe unsafeBitCast(loadURL, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_navigation_state": unsafe unsafeBitCast(state, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ssl_status": unsafe unsafeBitCast(ssl, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_free": unsafe unsafeBitCast(free, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_free_owned": unsafe unsafeBitCast(freeOwned, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_renderer_client_ids": unsafe unsafeBitCast(clientIDs, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_popup_window_bounds", "cmux_shim_devtools_inspected_bounds":
            unsafe unsafeBitCast(bounds, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_password_remove": unsafe unsafeBitCast(remove, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_load": unsafe unsafeBitCast(load, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_popup_window_attach": unsafe unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        default: unsafe unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
