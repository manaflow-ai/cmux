/// The transcript's process-wide pixel caches for the host's memory policy, with no platform type
/// (p07-memory-081): row bitmaps (`RowBitmaps`), decoded media (`MediaCache`), long-text tiles
/// (`TileCache`) and bubble outlines (`BubbleSlices`). Every view of the process shares them, so the
/// host sizes them once; cmux-next registers them with its memory coordinator
/// (CmuxNextHome's `MessagesLabMemoryConsumer`).
///
/// Everything dropped here is lossless: a row or tile on screen keeps the image its layer shows, and
/// the next miss draws or decodes it again off the main thread.
///
/// ```swift
/// let caches = MessagesLabTranscriptCaches()
/// caches.setBudget(bytes: share)   // caps only; the next store trims to them
/// caches.trim(toFraction: 0)       // frees every cached bitmap now
/// ```
@MainActor
public final class MessagesLabTranscriptCaches { // memory: consumer via MessagesLabMemoryConsumer (CmuxNextHome)
    private let rows: RowBitmaps
    private let media: MediaCache
    private let tiles: TileCache
    /// Whether ``trim(toFraction:)`` also frees the process's bubble outlines (only the shared caches own them).
    private let ownsSlices: Bool

    /// The caches every transcript view of the process draws from.
    public convenience init() {
        self.init(rows: .shared, media: .shared, tiles: .shared, ownsSlices: true)
    }

    init(rows: RowBitmaps, media: MediaCache, tiles: TileCache, ownsSlices: Bool) {
        self.rows = rows
        self.media = media
        self.tiles = tiles
        self.ownsSlices = ownsSlices
    }

    /// Pixel bytes the caches hold now. Read from counters, never a walk.
    public var bytes: Int {
        rows.bytes + media.bytes + tiles.bytes + (ownsSlices ? BubbleSlices.bytes : 0)
    }

    /// The bitmaps, images and tiles the caches hold now.
    public var entryCount: Int {
        rows.count + media.count + tiles.count
    }

    /// Caps the caches at `bytes` together, in MessagesLab's proportions (row bitmaps 160, media 96 and
    /// tiles 48 of 304). Frees nothing now: each cache trims to its cap at its next store. The lab's
    /// `--image-cache-mb` and `--tile-cache-mb` keep their caps.
    ///
    /// - Parameter bytes: The bytes the caches keep together, at most (negative counts as 0).
    public func setBudget(bytes: Int) {
        let total = max(0, bytes)
        let share = Self.shares(of: total)
        rows.setBudget(bytes: share.rows)
        media.setBudget(bytes: share.media)
        tiles.setBudget(bytes: share.tiles)
    }

    /// Frees now, the least recently used first, until at most `fraction` of ``bytes`` remain; `0`
    /// frees everything. The caps stay as they are.
    ///
    /// - Parameter fraction: The share of what the caches hold now to keep, 0...1 (NaN keeps all).
    public func trim(toFraction fraction: Double) {
        guard !fraction.isNaN, fraction < 1 else { return }
        rows.trim(toFraction: fraction)
        media.trim(toFraction: fraction)
        tiles.trim(toFraction: fraction)
        // The outlines are a few small images per bubble width: kept whole or dropped whole.
        if ownsSlices { BubbleSlices.removeAll() }
    }

    /// `total` split as MessagesLab sized its caches: 160 + 96 + 48 MB (10 : 6 : 3).
    static func shares(of total: Int) -> (rows: Int, media: Int, tiles: Int) {
        let unit = total / 19
        let rows = unit * 10, media = unit * 6
        return (rows, media, total - rows - media)
    }
}
