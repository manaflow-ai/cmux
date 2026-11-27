@testable import CmuxNextBrowser
import Foundation
import Testing

/// PL-burst (session cmux-1c, STRESS): every read of a profile's extension mirror refreshed it, a
/// synchronous Chromium call (`cmux_ext_list` and `cmux_ext_commands`) on the main thread. The
/// browser host reads it per Chromium tab on every tab-list change (about 40 reads per new tab,
/// Cmd-W or move: a 99.6 ms hang). A mirror is filled once when it is made; Chromium's
/// extension and action events (and a new window) refresh it, never a read.
@MainActor @Suite(.serialized) struct CEFExtensionStoreReadTests {
    @Test func fiftyReadsAskChromiumOnce() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root))
        let backend = MockExtensionBackend()
        let stores = CEFExtensionStores(runtime: runtime, makeBackend: { _ in backend })
        for _ in 0..<50 { _ = stores.readyStore(for: .default) }
        #expect(backend.snapshots == 1, "each read asked Chromium (\(backend.snapshots) snapshots)")
        stores.refreshAll()
        #expect(backend.snapshots == 2, "an extension event still refreshes the mirror")
    }
}
