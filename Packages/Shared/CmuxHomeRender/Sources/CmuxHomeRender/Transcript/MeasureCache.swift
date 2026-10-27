import CmuxHomeCore
import CoreGraphics
import Foundation

/// Measured bubbles by (item key, part index). A wrap-width change re-asks
/// Core Text only for parts whose lines can change (`TextLayout.isValid`);
/// every other part keeps its layout, so its row spec and bitmap stay equal.
///
/// Every commit reads one entry per shown part, and the model's rows share
/// its layouts, so the cache is the transcript's working set: it follows the
/// loaded items (`trim(keeping:)`) and no memory policy drops it. `bytes`
/// estimates what it holds, for the memory report, from counters it keeps
/// (entries, lines, ranges and text), never from a walk on read.
@MainActor
final class MeasureCache { // memory: consumer via HomeRenderMemoryConsumer (CmuxNextHome)
    struct Key: Hashable {
        var item: IdempotencyKey
        var part: Int
    }

    struct Entry {
        var text: String
        var bold: [NSRange]
        var wrapWidth: CGFloat
        var layout: TextLayout
        var size: CGSize
    }

    private var entries: [Key: Entry] = [:]
    /// Core Text measurements made (tests read it to prove reflow skips rows).
    private(set) var measureCount = 0
    /// Estimated bytes of the kept measurements.
    private(set) var bytes = 0

    /// Kept measurements.
    var count: Int { entries.count }

    func measure(item: IdempotencyKey, part: Int, text: String, bold: [NSRange], wrapWidth: CGFloat) -> Entry {
        let key = Key(item: item, part: part)
        if var cached = entries[key], cached.text == text, cached.bold == bold {
            if cached.layout.isValid(atMaxWidth: wrapWidth, measuredAt: cached.wrapWidth) {
                if cached.wrapWidth != wrapWidth {
                    cached.wrapWidth = wrapWidth
                    entries[key] = cached
                }
                return cached
            }
        }
        measureCount += 1
        let layout = TextLayout.make(text, bold: bold, maxWidth: wrapWidth, font: Style.bodyFont)
        let size = CGSize(width: min(layout.width, wrapWidth) + 2 * Style.bubblePadX,
                          height: CGFloat(layout.lines.count) * Style.lineHeight + 2 * Style.bubblePadY)
        let entry = Entry(text: text, bold: bold, wrapWidth: wrapWidth, layout: layout, size: size)
        let replaced = entries.updateValue(entry, forKey: key)
        bytes += Self.bytes(of: entry) - (replaced.map { Self.bytes(of: $0) } ?? 0)
        return entry
    }

    /// Drops measurements of items that left the transcript.
    func trim(keeping items: Set<IdempotencyKey>) {
        guard entries.count > 2 * items.count + 200 else { return }
        entries = entries.filter { items.contains($0.key.item) }
        bytes = entries.values.reduce(0) { $0 + Self.bytes(of: $1) }
    }

    /// An entry's estimated bytes: the key and entry, its lines, its bold
    /// ranges (kept twice) and its text's UTF-8 (one copy: entry and layout
    /// share it).
    private static func bytes(of entry: Entry) -> Int {
        MemoryLayout<Key>.stride + MemoryLayout<Entry>.stride
            + entry.layout.lines.count * MemoryLayout<TextLayout.Line>.stride
            + 2 * entry.bold.count * MemoryLayout<NSRange>.stride
            + entry.text.utf8.count
    }
}
