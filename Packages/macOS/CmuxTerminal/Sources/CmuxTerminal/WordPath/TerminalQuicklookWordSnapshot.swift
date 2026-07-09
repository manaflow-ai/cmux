/// A `Sendable` snapshot of Ghostty's QuickLook-word extraction for one
/// command-click resolution pass.
///
/// The live `ghostty_surface_quicklook_word` read stays app-side (it dereferences
/// the `ghostty_surface_t` and decodes the runtime's text buffer); this value is
/// what the app conformer of ``TerminalWordPathHosting`` vends across the seam so
/// the package can drive the cmd-click resolution precedence without ever touching
/// the live surface pointer.
///
/// `decodedWord` is the UTF-8-decoded QuickLook word, or `nil` when the runtime
/// reported an empty/undecodable word (the QuickLook resolution is then skipped).
/// `viewportOffsetStart` is the visible-grid offset the word started at, or `nil`
/// when the runtime reported no offset span (the viewport resolution is then
/// skipped). The two fields gate their resolutions exactly as the legacy
/// `text.text_len > 0` / `text.offset_len > 0` checks did.
public struct TerminalQuicklookWordSnapshot: Sendable {
    /// The decoded QuickLook word under the cursor, or `nil` when the runtime
    /// reported no decodable word.
    public let decodedWord: String?

    /// The visible-grid offset the QuickLook word started at, or `nil` when the
    /// runtime reported no offset span.
    public let viewportOffsetStart: Int?

    /// Creates a QuickLook-word snapshot.
    ///
    /// - Parameters:
    ///   - decodedWord: The decoded QuickLook word, or `nil` when undecodable.
    ///   - viewportOffsetStart: The visible-grid offset start, or `nil` when the
    ///     runtime reported no offset span.
    public init(decodedWord: String?, viewportOffsetStart: Int?) {
        self.decodedWord = decodedWord
        self.viewportOffsetStart = viewportOffsetStart
    }
}
