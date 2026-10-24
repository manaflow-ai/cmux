import Foundation
@testable import CmuxNextBrowser
import Testing

/// The Chromium framework's dlopen runs on the main thread (manaflow-ai/cmux#23821): its PartitionAlloc
/// static constructor swaps the process's default malloc zone inside that dlopen. On a pool thread
/// (Task.detached, as before) the swap raced the main thread's own allocations at launch and damaged the
/// heap (EXC_BAD_ACCESS in BrowserHostProvider.sendTabChanges, a tiny free-list link 0x8000000000000000).
/// The expensive part, reading the 367 MiB binary into the page cache, stays off the main thread.
@Suite struct CEFFrameworkMapThreadTests {
    /// Records the thread each `cmux_shim_load` (the framework dlopen) ran on.
    final class LoadSpy: @unchecked Sendable { // test-only spy: written once per call from the call's thread, read after
        nonisolated(unsafe) static var onMain: [Bool] = []
    }

    static func spyShim() throws -> CEFShimLibrary {
        let load: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32 = { _, _, _ in
            LoadSpy.onMain.append(pthread_main_np() == 1)
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            name == "cmux_shim_load" ? unsafeBitCast(load, to: UnsafeMutableRawPointer.self)
                : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }

    @Test func theFrameworkDlopenRunsOnTheMainThreadWhicheverThreadPreparedIt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "cef-map-\(UUID().uuidString)")
        let layout = CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root)
        let shim = try Self.spyShim()
        let prepared = await Task.detached { CEFRuntime.prepared(shim: shim, layout: layout) }.value
        LoadSpy.onMain = []
        let loaded = await CEFRuntime.mapFramework(prepared)
        #expect((try? loaded.get()) != nil)
        #expect(LoadSpy.onMain == [true], "the framework's static constructors (the zone swap) ran off the main thread")
    }
}
