public import Foundation

/// One ordered element of a terminal surface's output stream: a frame's
/// metadata together with the VT bytes that realize it.
///
/// Metadata and bytes for the SAME frame must be applied back-to-back, in
/// stream order: the Stage 1 local-scroll engine arms decisions from a frame's
/// metadata (active-screen routing, deeper-fetch classification, the scroll
/// restore after a deeper-scrollback snapshot) and consumes them when that
/// frame's bytes apply. Delivering both as one element makes that ordering
/// structural. Metadata previously rode a separate stream, which raced the
/// byte stream three ways: a frame's bytes could apply before their own
/// metadata (dropping an armed restore), an interleaved live frame could
/// consume a restore armed for a later snapshot, and a restore armed while the
/// reader scrolled back to the bottom could go stale and fire much later.
public struct MobileTerminalOutputChunk: Sendable {
    /// Per-frame metadata for the terminal view's local-scroll gates.
    public struct FrameMeta: Sendable {
        /// Whether the active screen is the alternate screen (TUI). Primary
        /// scrolls locally; alternate forwards to the Mac.
        public let isAlternateScreen: Bool
        /// Whether this frame was a full snapshot (it rebuilt the local
        /// surface at the live bottom and flowed ``scrollbackRows`` of
        /// history).
        public let isFullSnapshot: Bool
        /// Scrollback rows flowed into the local surface by a full snapshot.
        /// Zero for a delta (a delta grows no local history).
        public let scrollbackRows: Int

        public init(isAlternateScreen: Bool, isFullSnapshot: Bool, scrollbackRows: Int) {
            self.isAlternateScreen = isAlternateScreen
            self.isFullSnapshot = isFullSnapshot
            self.scrollbackRows = scrollbackRows
        }
    }

    /// The frame's metadata, or `nil` for raw PTY bytes (older Mac hosts /
    /// compatibility fallback), which carry no frame identity.
    public let meta: FrameMeta?
    /// VT bytes to feed into the local libghostty surface. May be empty for a
    /// metadata-only frame (e.g. a no-row-change frame that flips the active
    /// screen).
    public let bytes: Data

    public init(meta: FrameMeta? = nil, bytes: Data) {
        self.meta = meta
        self.bytes = bytes
    }
}
