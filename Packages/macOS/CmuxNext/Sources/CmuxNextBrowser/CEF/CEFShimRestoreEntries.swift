import Foundation

/// Fork API 31's `cmux_shim_tab_restore_entries`: a list of entries (address and title, no page state) into a
/// browser created with an empty URL that has not navigated, loading entry `current`. Each
/// `cmux_shim_restore_entry` is six machine words: url, url_length, title, title_length, page_state,
/// page_state_length (cmux_cef_shim.h), with UTF-8 text and explicit lengths. The texts live in one buffer for
/// the call; the shim copies them before it returns (in host mode the remote shim serializes them).
@safe
// crash-allow: one immutable C function pointer from a shim handle never closed (or a test's stand-in), as CEFShimLibrary
nonisolated struct CEFShimRestoreEntries: @unchecked Sendable {
    typealias Fn = @convention(c) (Int32, UnsafeRawPointer?, Int32, Int32) -> Int32
    private let call: Fn

    init?(_ call: Fn?) {
        guard let call = unsafe call else { return nil }
        unsafe self.call = call
    }

    /// The shim's answer (1 restored); in host mode a stand-in that callers never read.
    func callAsFunction(_ browser: Int32, _ entries: [BrowserSavedEntry], current: Int32) -> Int32 {
        let texts = entries.flatMap { [Array($0.url.absoluteString.utf8), Array(($0.title ?? "").utf8)] }
        let storage = unsafe UnsafeMutableRawPointer.allocate(byteCount: max(texts.reduce(0) { $0 + $1.count }, 1), alignment: 1)
        defer { unsafe storage.deallocate() }
        var words: [Int] = []
        words.reserveCapacity(entries.count * 6)
        var offset = 0
        for (index, text) in texts.enumerated() {
            let start = unsafe storage.advanced(by: offset)
            unsafe text.withUnsafeBytes { bytes in
                if let from = bytes.baseAddress { unsafe start.copyMemory(from: from, byteCount: bytes.count) }
            }
            words += [unsafe Int(bitPattern: start), text.count]
            offset += text.count
            if index % 2 == 1 { words += [0, 0] }  // no page state
        }
        return unsafe words.withUnsafeBytes { unsafe call(browser, $0.baseAddress, Int32(entries.count), current) }
    }
}
