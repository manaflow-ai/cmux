import CmuxNextCompat
import Foundation

/// The pages the first window never shows ship raw-deflated (CMUX-570, app size): the pages
/// builder (webviews/scripts/pages/pack-pages.mjs) replaces each `pages/__shared` script that Home
/// and the first window cannot reach, every packed page's entry (`__shared/page-<page>.js`)
/// included, by `<name>.js.deflate`. Both engines ask ``PageSchemeHandler`` for every `__shared`
/// file, so ``PageSchemeHandler/read(_:)`` serves a missing file from its packed copy through this.
///
/// A file is inflated in memory each time a page asks for it; Settings' first paint inflates about
/// 200 KB into 1.5 MB in a few milliseconds, so nothing keeps it. Nothing is written outside the
/// signed bundle: a first-party page's code never comes from a folder another process can write
/// (``PageWebView/mayServe(_:from:testRoot:)``). The agent pane's lazy `chunks/` ship the same way
/// in the app (scripts/cmux-next/pack-webviews-chunks.py), read by its own handler through this too.
nonisolated public struct PagePackedFile {
    public nonisolated init() {}
    /// The suffix pack-pages.mjs gives a packed file (its `PACKED_SUFFIX`).
    public static let suffix = ".deflate"

    /// `file`'s bytes from its packed copy (`file` + ``suffix``), nil when there is none or it does
    /// not inflate. It reads the disk: call it off the main actor, as ``PageSchemeHandler/read(_:)``.
    public static func read(_ file: URL) -> Data? {
        // The packed copy sits beside the file it stands for, as the route resolved it: a link that
        // leads anywhere else is not followed (PageSchemeHandler.route's symlink rule).
        let packed = URL(fileURLWithPath: file.path + suffix).standardizedFileURL.resolvingSymlinksInPath()
        guard packed.deletingLastPathComponent().path == file.standardizedFileURL.deletingLastPathComponent().path,
              let stored = try? Data(blockingContentsOf: packed, options: .mappedIfSafe) else { return nil }
        return inflate(stored)
    }

    /// Raw DEFLATE (RFC 1951, what node's `deflateRawSync` writes): Compression's `zlib` algorithm.
    static func inflate(_ stored: Data) -> Data? {
        try? (stored as NSData).decompressed(using: .zlib) as Data
    }
}
