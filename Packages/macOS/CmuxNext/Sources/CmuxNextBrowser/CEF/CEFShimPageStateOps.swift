import CmuxNextCompat
import Foundation

/// The shim's page state calls (fork API 31, tasks p01-process-227 and 093): a watch that reports
/// each history entry whose page state (scroll offsets, form values) commits or changes, the read
/// of one entry's encoded page state, and the restore of entries with theirs into a new browser,
/// as Chrome restores a session's `SerializedNavigationEntry`s with their `encoded_page_state`
/// (components/sessions/content/content_serialized_navigation_builder.cc). In host mode the watch
/// and the read are the remote shim's local exports (the host pushes each changed entry at idle
/// and the read answers from what it kept); the restore is one post.
nonisolated struct CEFShimPageStateOps {
    /// The fork API that has the three calls.
    static let forkAPI: Int32 = 31

    /// fn(context, browser, index): entry `index` of `browser` committed or its page state changed.
    typealias WatchFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void

    /// browser, fn (nil ends the watch), context -> 1 when watching.
    let watch: @convention(c) (Int32, WatchFn?, UnsafeMutableRawPointer?) -> Int32
    /// browser, index -> the entry's encoded page state; nil for none or an unknown entry.
    let entryPageState: (Int32, Int32) -> String?
    /// browser, entries, current -> 1 when restored (in host mode: when sent), else the fork's code
    /// (0 unknown browser, -1 committed entries, -2 navigation not dropped, -3 bad entries).
    let restoreEntries: (Int32, [BrowserSavedEntry], Int32) -> Int32

    // SAFETY (every `unsafe` here): `r` resolves each export of a shim whose ABI identity matched
    // (CEFShimLibrary's own rule), so each cast is the export's C type in cmux_cef_shim.h; a returned
    // string is the shim's allocation, copied and freed once with `free`; the restore's records point
    // into one byte buffer alive for the call alone, and the shim copies what it keeps.
    init(_ r: CEFShimLibrary.Resolver, free: CEFShimLibrary.FreeFn) throws(CEFShimLibrary.LoadError) {
        watch = try unsafe r("cmux_shim_tab_page_state_watch")
        let cRead: @convention(c) (Int32, Int32) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_tab_entry_page_state")
        entryPageState = { browser, index in
            guard let pointer = unsafe cRead(browser, index) else { return nil }
            defer { unsafe free(pointer) }
            return unsafe String(cString: pointer)
        }
        let cRestore: @convention(c) (Int32, UnsafeRawPointer?, Int32, Int32) -> Int32 = try unsafe r("cmux_shim_tab_restore_entries")
        restoreEntries = { browser, entries, current in
            unsafe Self.withRecords(entries) { records, count in unsafe cRestore(browser, records, count, current) }
        }
    }

    /// `entries` as `cmux_shim_restore_entry` records (url, title, page state, each a UTF-8 pointer
    /// and its length) for `body`'s call alone. On the 64-bit targets cmux builds a pointer and a
    /// `size_t` are one word each, so a record is six words.
    static func withRecords<Result>(_ entries: [BrowserSavedEntry], _ body: (UnsafeRawPointer?, Int32) -> Result) -> Result {
        var bytes: [UInt8] = []
        var spans: [(offset: Int, count: Int)] = []
        for entry in entries {
            for text in [entry.url.absoluteString, entry.title ?? "", entry.pageState ?? ""] {
                spans.append((bytes.count, text.utf8.count))
                bytes.append(contentsOf: text.utf8)
            }
        }
        return unsafe bytes.withUnsafeBufferPointer { buffer in
            let base = unsafe UInt(bitPattern: buffer.baseAddress)
            var words: [UInt] = []
            words.reserveCapacity(spans.count * 2)
            for span in spans {
                // An empty string is NULL with length 0 (the header's "none").
                words.append(span.count == 0 ? 0 : base + UInt(span.offset))
                words.append(UInt(span.count))
            }
            return unsafe words.withUnsafeBytes { unsafe body($0.baseAddress, Int32(clamping: entries.count)) }
        }
    }
}

/// The seam adapter of the page state watch's C entry. In process the fork calls it on Chromium's
/// UI thread, which is the main thread, possibly inside a call cmux made (a restore's commit); in
/// host mode the remote shim calls it on the main thread from the host's push. The tab takes the
/// report now and reads the entry on a later run-loop turn (`CEFTab.pageStateReported(index:)`).
nonisolated enum CEFPageStateCallbacks {
    static let watch: CEFShimPageStateOps.WatchFn = { context, browser, index in
        // SAFETY: only the token's bits; CEFRuntime.from resolves it or ignores it.
        let address = unsafe UInt(bitPattern: context)
        guard address != 0 else { return }
        let report: @MainActor () -> Void = { CEFRuntime.from(address)?.tabsByBrowser[browser]?.pageStateReported(index: index) }
        guard Thread.isMainThread else { return MainRunLoopBlock.perform(report) }
        MainActor.assumeIsolated { report() } // main-proof: guarded by Thread.isMainThread above
    }
}
