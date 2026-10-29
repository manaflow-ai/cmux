/// The transcript's process-wide pixel caches for the host's memory policy, with no platform type:
/// row bitmaps (`RowBitmaps`), decoded media (`MediaCache`), long-text tiles
/// (`TileCache`), bubble outlines (`BubbleSlices`), and since p07-memory-115 the pictures Markdown
/// shows (`HomeMarkdownImages`) and the text measurements (`MeasureCache`). Every view of the process
/// shares them, so the host sizes them once; cmux-next registers them with its memory coordinator
/// (CmuxNextHome's `MessagesLabMemoryConsumer`).
///
/// Everything dropped here is lossless: a row or tile on screen keeps the image its layer shows, and
/// the next miss draws or decodes it again off the main thread. A trim drops the least recently asked
/// parts' text layouts and keeps each part's estimate basis, so the next layout measures only the rows
/// near the viewport again and estimates the rest, as before the trim.
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
    private let markdownImages: HomeMarkdownImages?
    private let measurements: MeasureCache?
    /// Whether ``trim(toFraction:)`` also frees the process's bubble outlines (only the shared caches own them).
    private let ownsSlices: Bool

    /// The caches every transcript view of the process draws from.
    public convenience init() {
        self.init(rows: .shared, media: .shared, tiles: .shared, ownsSlices: true,
                  markdownImages: HomeMarkdownPolicy.images, measurements: MeasureCache.shared)
    }

    init(rows: RowBitmaps, media: MediaCache, tiles: TileCache, ownsSlices: Bool,
         markdownImages: HomeMarkdownImages? = nil, measurements: MeasureCache? = nil) {
        self.rows = rows
        self.media = media
        self.tiles = tiles
        self.ownsSlices = ownsSlices
        self.markdownImages = markdownImages
        self.measurements = measurements
    }

    /// Bytes the caches hold now: pixels, and the text measurements' estimate. Read from counters, never a walk.
    public var bytes: Int {
        rows.bytes + media.bytes + tiles.bytes + (markdownImages?.bytes ?? 0) + (ownsSlices ? BubbleSlices.bytes : 0)
            + (measurements?.bytes ?? 0)
    }

    /// The bitmaps, images, tiles and exact text measurements the caches hold now.
    public var entryCount: Int {
        rows.count + media.count + tiles.count + (markdownImages?.count ?? 0) + (measurements?.count ?? 0)
    }

    /// Caps the caches at `bytes` together, in MessagesLab's proportions (row bitmaps 160, media 96 and
    /// tiles 48 of 304) plus Markdown's pictures (32, of 336 in all). Frees nothing now: each cache trims to
    /// its cap at its next store. The lab's `--image-cache-mb` and `--tile-cache-mb` keep their caps.
    ///
    /// - Parameter bytes: The bytes the caches keep together, at most (negative counts as 0).
    public func setBudget(bytes: Int) {
        let total = max(0, bytes)
        let share = Self.shares(of: total)
        rows.setBudget(bytes: share.rows)
        media.setBudget(bytes: share.media)
        tiles.setBudget(bytes: share.tiles)
        markdownImages?.setBudget(bytes: share.markdown)
    }

    /// Frees now, the least recently used first, until at most `fraction` of ``bytes`` remain; `0`
    /// frees every bitmap, picture and text layout (the measurements' estimate bases stay). The caps stay as they are.
    ///
    /// - Parameter fraction: The share of what the caches hold now to keep, 0...1 (NaN keeps all).
    public func trim(toFraction fraction: Double) {
        guard !fraction.isNaN, fraction < 1 else { return }
        rows.trim(toFraction: fraction)
        media.trim(toFraction: fraction)
        tiles.trim(toFraction: fraction)
        markdownImages?.trim(toFraction: fraction)
        measurements?.trim(toFraction: fraction)
        // The outlines are a few small images per bubble width: kept whole or dropped whole.
        if ownsSlices { BubbleSlices.removeAll() }
    }

    /// `total` split as MessagesLab sized its caches, 160 + 96 + 48 MB, and Markdown's pictures 32 MB
    /// (10 : 6 : 3 : 2).
    static func shares(of total: Int) -> (rows: Int, media: Int, tiles: Int, markdown: Int) {
        let unit = total / 21
        let rows = unit * 10, media = unit * 6, markdown = unit * 2
        return (rows, media, total - rows - media - markdown, markdown)
    }
}
