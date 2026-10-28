@testable import CmuxNextBrowser
import Foundation
import Testing

/// p09-observability-106: Chromium's own HangWatcher in the browser process dumps to cmux through the fork's
/// `cmux_set_hang_dump_handler` (shim `cmux_cef_set_dump_handler`). One capture is one record; the fork's arrays are
/// read inside the call; the watcher's switch goes only to a fork that took the handler, and children keep theirs off.
@Suite(.serialized) struct CEFHangDumpsTests {
    /// Calls the C entry with one capture of `threads` (name, kind, overrun µs, frames), as the fork lays it out.
    private static func deliver(_ threads: [(name: String?, kind: Int32, overrunMicros: Int64, frames: [UInt])],
                                to context: UnsafeMutableRawPointer?) {
        let ids = threads.indices.map { UInt64(700 + $0) }
        let kinds = threads.map(\.kind)
        let overruns = threads.map(\.overrunMicros)
        let frameCounts = threads.map { Int32($0.frames.count) }
        let frames = threads.flatMap(\.frames)
        let names = threads.map { thread in thread.name.flatMap { unsafe strdup($0) } }
        defer { for name in names { unsafe free(name) } }
        let constNames = names.map { unsafe $0.map { unsafe UnsafePointer($0) } }
        // SAFETY: each array lives for the call, holding `count` entries (frames: the sum of the frame counts); the
        // names are NUL-terminated copies freed after it.
        unsafe cefHangDumpCallback(context, Int32(threads.count), ids, kinds, overruns, constNames, frameCounts, frames)
    }

    @Test func aSyntheticCaptureGivesOneRecordWithTheThreadsNameKindOverrunAndFrames() {
        HangDumpSpy.reset()
        let dumps = CEFHangDumps(deliver: HangDumpSpy.record)
        // SAFETY: `dumps` outlives the call; the entry reads the context without taking a retain.
        let context = unsafe Unmanaged.passUnretained(dumps).toOpaque()
        unsafe Self.deliver([(name: "Chrome_IOThread", kind: 0, overrunMicros: 2_000_000, frames: [0x1000, 0x2000, 0x3000])],
                            to: context)
        #expect(HangDumpSpy.captures.count == 1)
        let thread = HangDumpSpy.captures.first?.first
        #expect(thread == ChromiumHungThread(threadID: 700, kind: .io, name: "Chrome_IOThread", overrun: .seconds(2),
                                             addresses: [0x1000, 0x2000, 0x3000]))
        #expect(thread?.watchName == "chromium.io")
    }

    @Test func eachThreadGetsItsOwnFramesFromTheSharedArray() {
        HangDumpSpy.reset()
        let dumps = CEFHangDumps(deliver: HangDumpSpy.record)
        // SAFETY: as above.
        let context = unsafe Unmanaged.passUnretained(dumps).toOpaque()
        unsafe Self.deliver([(name: "Chrome_IOThread", kind: 0, overrunMicros: 3_000_000, frames: [1, 2]),
                             (name: nil, kind: 2, overrunMicros: 1_000, frames: []),
                             (name: "ThreadPoolForegroundWorker", kind: 2, overrunMicros: 5, frames: [7, 8, 9])], to: context)
        let threads = HangDumpSpy.captures.first ?? []
        #expect(HangDumpSpy.captures.count == 1, "one capture is one record, however many threads it names")
        #expect(threads.map(\.addresses) == [[1, 2], [], [7, 8, 9]])
        #expect(threads.map(\.name) == ["Chrome_IOThread", "", "ThreadPoolForegroundWorker"])
        #expect(threads.map(\.watchName) == ["chromium.io", "chromium.pool", "chromium.pool"])
    }

    @Test func aCaptureWithNothingReadableIsNoRecord() {
        HangDumpSpy.reset()
        let dumps = CEFHangDumps(deliver: HangDumpSpy.record)
        // SAFETY: as above.
        let context = unsafe Unmanaged.passUnretained(dumps).toOpaque()
        unsafe Self.deliver([], to: context)
        unsafe Self.deliver([(name: "x", kind: 9, overrunMicros: 1, frames: [1])], to: context)  // a kind this build does not know
        unsafe Self.deliver([(name: "Chrome_IOThread", kind: 0, overrunMicros: 1, frames: [1])], to: nil)  // no context
        #expect(HangDumpSpy.captures.isEmpty)
    }

    @Test func aFrameCountPastTheCapIsCutAndTheNextThreadStillReadsItsOwn() {
        HangDumpSpy.reset()
        let dumps = CEFHangDumps(deliver: HangDumpSpy.record)
        // SAFETY: as above.
        let context = unsafe Unmanaged.passUnretained(dumps).toOpaque()
        let long = (0..<UInt(ChromiumHungThread.maxFrames + 6)).map { $0 + 1 }
        unsafe Self.deliver([(name: "a", kind: 0, overrunMicros: 1, frames: long), (name: "b", kind: 2, overrunMicros: 1, frames: [99])],
                            to: context)
        let threads = HangDumpSpy.captures.first ?? []
        #expect(threads.first?.addresses == Array(long.prefix(ChromiumHungThread.maxFrames)))
        #expect(threads.last?.addresses == [99])
    }

    @Test func theRuntimeGivesTheForkItsHandlerOnlyInProcessWithASinkAndTheForksAPI() throws {
        let root = URL(filePath: "/nonexistent/cmux-hang-dumps")
        HangDumpSpy.reset()
        HangDumpSpy.forkAPI = CEFForkFeatures.hangDumpForkAPI
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(HangDumpSpy.symbol), storage: CEFProfileStorage(root: root))
        let shim = try CEFShimLibrary.resolving(HangDumpSpy.symbol)
        #expect(!runtime.installHangDumps(shim, inProcess: true), "no sink: Chromium's watcher stays off")
        runtime.chromiumHangSink = HangDumpSpy.record
        #expect(!runtime.installHangDumps(shim, inProcess: false), "host mode: the host keeps its own watch")
        HangDumpSpy.forkAPI = CEFForkFeatures.hangDumpForkAPI - 1
        #expect(!runtime.installHangDumps(shim, inProcess: true), "an older fork gets no handler")
        #expect(HangDumpSpy.handler == nil)
        HangDumpSpy.forkAPI = CEFForkFeatures.hangDumpForkAPI
        #expect(runtime.installHangDumps(shim, inProcess: true))
        #expect(runtime.installHangDumps(shim, inProcess: true), "a second start keeps the handler the fork took")
        #expect(HangDumpSpy.installs == 1)
        // The fork calls the handler it took: one capture, one record in the App's sink.
        let handler = try #require(HangDumpSpy.handler)
        HangDumpSpy.captures = []
        let ids: [UInt64] = [1], kinds: [Int32] = [2], overruns: [Int64] = [10], counts: [Int32] = [1], frames: [UInt] = [42]
        let names: [UnsafePointer<CChar>?] = [nil]
        // SAFETY: the arrays live for the call; the context is the one the runtime retained for the process.
        unsafe handler(HangDumpSpy.context, 1, ids, kinds, overruns, names, counts, frames)
        #expect(HangDumpSpy.captures.map { $0.map(\.addresses) } == [[[42]]])
    }

    @Test func aShimThatRefusesTheHandlerLeavesTheWatcherOff() throws {
        HangDumpSpy.reset()
        HangDumpSpy.forkAPI = CEFForkFeatures.hangDumpForkAPI
        HangDumpSpy.accepts = false
        let shim = try CEFShimLibrary.resolving(HangDumpSpy.symbol)
        #expect(CEFHangDumps.install(on: shim, deliver: HangDumpSpy.record) == nil)
        let missing = try CEFShimLibrary.resolving { $0 == "cmux_cef_set_dump_handler" ? nil : HangDumpSpy.symbol($0) }
        #expect(!CEFForkFeatures(missing).hangDumps, "a shim without the export has no hang dumps at any fork API")
    }
}

/// A fake shim: `cmux_cef_set_dump_handler` keeps the handler and context, `cmux_shim_fork_api_version` answers
/// ``forkAPI``; every other export does nothing and answers 0.
private nonisolated enum HangDumpSpy {
    // crash-allow: test-only spy state, written and read on the serialized suite's one thread at a time.
    nonisolated(unsafe) static var captures: [[ChromiumHungThread]] = []
    // crash-allow: as above.
    nonisolated(unsafe) static var forkAPI: Int32 = 0
    // crash-allow: as above.
    nonisolated(unsafe) static var accepts = true
    // crash-allow: as above.
    nonisolated(unsafe) static var installs = 0
    // crash-allow: as above.
    nonisolated(unsafe) static var handler: CEFShimLibrary.HangDumpFn?
    // crash-allow: as above.
    nonisolated(unsafe) static var context: UnsafeMutableRawPointer?

    static func reset() {
        (captures, forkAPI, accepts, installs) = ([], 0, true, 0)
        unsafe (handler, context) = (nil, nil)
    }

    /// The App's sink: each capture as it came.
    static let record: @Sendable ([ChromiumHungThread]) -> Void = { threads in HangDumpSpy.captures.append(threads) }

    // SAFETY (every `unsafe` below): each closure is a C function of its export's type in cmux_cef_shim.h.
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let setHandler: @convention(c) (CEFShimLibrary.HangDumpFn?, UnsafeMutableRawPointer?) -> Int32 = { fn, ctx in
            guard HangDumpSpy.accepts else { return 0 }
            HangDumpSpy.installs += 1
            unsafe (HangDumpSpy.handler, HangDumpSpy.context) = (fn, ctx)
            return 1
        }
        let forkAPI: @convention(c) () -> Int32 = { HangDumpSpy.forkAPI }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_cef_set_dump_handler": unsafe unsafeBitCast(setHandler, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafe unsafeBitCast(forkAPI, to: UnsafeMutableRawPointer.self)
        default: unsafe unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
