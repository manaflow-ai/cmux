import AppKit
import CmuxNextCompat

/// One bitmap per drawn glyph, shared by every image of it (REOPEN-F7 part A2; Chrome's shared image cache).
///
/// `NSImage.icon` used to return a drawing-handler image, and AppKit keeps one raster per image instance: N views
/// showing the same glyph rasterized it N times on the main thread, in the first display pass of a reopened window
/// (37-43 ms of AppKit work before the first frame). Each key here is drawn once, from any thread, and every image
/// of it wraps the same bitmap. Chrome glyphs are templates (black ink, tinted by their view), so the light/dark
/// appearance is not part of a key; the drawing (pack layers or SF Symbol), the side and the scale are.
///
/// Bounded: at most `limit` bitmaps and `byteLimit` bytes, the least recently used dropped first; all of them dropped
/// on a memory pressure warning. Thread-safe: one unfair lock held only to look up or store (drawing runs outside it),
/// never a hop to the main thread.
nonisolated final class IconRasters: Sendable {
    /// The app-wide cache: immutable bitmaps keyed by value, no app state (arch exception
    /// plans/cmux-next/arch-exceptions/icon-rasters.json: ~105 callers of the static `NSImage.icon` API).
    fileprivate static let shared = IconRasters()

    /// The scales a chrome glyph is drawn at: every Mac display is 1x or 2x.
    static let scales: [CGFloat] = [1, 2]

    /// What is drawn: the icon's name and style, or the SF Symbol it stands for, and the pack's family overlay: with
    /// those a key always resolves to one drawing.
    struct Glyph: Hashable {
        let name: String
        let style: IconStyle
        let symbol: String?
        /// The pack family overlay in use (`IconPack.useOverlay`), so a bitmap drawn before it changes is not reused.
        var overlay: String? = IconPack.overlay
    }

    struct Key: Hashable {
        let glyph: Glyph
        let side: CGFloat
        let scale: CGFloat
    }

    private struct Entry {
        let bitmap: CGImage
        var used: UInt64
        var bytes: Int { bitmap.bytesPerRow * bitmap.height }
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var bytes = 0
        /// A use counter: the entry with the lowest `used` is the least recently used.
        var clock: UInt64 = 0
        var pressure: (any DispatchSourceMemoryPressure)?
    }

    private let state = Mutex(State())
    private let limit: Int
    private let byteLimit: Int

    /// - Parameters:
    ///   - limit: The most bitmaps kept.
    ///   - byteLimit: The most bitmap bytes kept.
    ///   - dropsOnMemoryPressure: Drop every bitmap on a memory pressure warning (tests pass false).
    init(limit: Int = 512, byteLimit: Int = 8 << 20, dropsOnMemoryPressure: Bool = true) {
        self.limit = limit
        self.byteLimit = byteLimit
        guard dropsOnMemoryPressure else { return }
        state.withLock { state in
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.removeAll() }
            source.activate()
            state.pressure = source
        }
    }

    /// The number of bitmaps kept.
    var count: Int { state.withLock { $0.entries.count } }

    /// Drops every bitmap (they are drawn again when next asked for).
    func removeAll() {
        state.withLock { state in
            state.entries.removeAll()
            state.bytes = 0
        }
    }

    /// The bitmap of `glyph` at `side` points and `scale`, drawn the first time it is asked for (`resolve` gives its
    /// drawing then).
    func bitmap(_ glyph: Glyph, side: CGFloat, scale: CGFloat, resolve: () -> IconResolution) -> CGImage? {
        let key = Key(glyph: glyph, side: side, scale: scale)
        let kept = state.withLock { state -> CGImage? in
            guard state.entries[key] != nil else { return nil }
            state.clock &+= 1
            state.entries[key]?.used = state.clock
            return state.entries[key]?.bitmap
        }
        if let kept { return kept }
        // Drawn outside the lock: two threads may draw one key at once; the first stored wins, both are equal.
        guard let drawn = Self.draw(resolve(), side: side, scale: scale) else { return nil }
        return state.withLock { state in
            state.clock &+= 1
            if let first = state.entries[key]?.bitmap {
                state.entries[key]?.used = state.clock
                return first
            }
            let entry = Entry(bitmap: drawn, used: state.clock)
            state.entries[key] = entry
            state.bytes += entry.bytes
            while state.entries.count > limit || state.bytes > byteLimit,
                  let oldest = state.entries.min(by: { $0.value.used < $1.value.used }), oldest.key != key {
                state.entries[oldest.key] = nil
                state.bytes -= oldest.value.bytes
            }
            return drawn
        }
    }

    /// A template image of `glyph` at `side` points: one bitmap representation per scale, each the shared bitmap.
    /// Every call returns its own image, so a caller that sets its size or description changes no other.
    func image(_ glyph: Glyph, side: CGFloat, resolve: () -> IconResolution) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        for scale in Self.scales {
            guard let bitmap = bitmap(glyph, side: side, scale: scale, resolve: resolve) else { continue }
            let rep = NSBitmapImageRep(cgImage: bitmap)
            rep.size = NSSize(width: side, height: side)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    /// Draws `drawing` in black on a clear `side` x `side` point square at `scale`.
    private static func draw(_ drawing: IconResolution, side: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        switch drawing {
        case .drawing(let layers):
            // `drawIcon` draws y-down.
            context.translateBy(x: 0, y: CGFloat(pixels))
            context.scaleBy(x: 1, y: -1)
            context.drawIcon(layers, in: rect, grid: IconPack.bundled.grid, ink: CGColor(gray: 0, alpha: 1))
        case .system(let symbol):
            // Lay out like a pack icon: the symbol fitted and centered in the square, keeping its proportions.
            let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration),
                  glyph.size.width > 0, glyph.size.height > 0 else { return context.makeImage() }
            context.scaleBy(x: scale, y: scale)
            let fit = min(side / glyph.size.width, side / glyph.size.height)
            let size = NSSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
            let box = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            glyph.draw(in: box)
            NSGraphicsContext.current = previous
        }
        return context.makeImage()
    }
}

extension NSImage {
    /// The shared bitmaps (``IconRasters``) of `glyph` at `side` points: only `NSImage.icon` reaches the cache.
    nonisolated static func rasterIcon(_ glyph: IconRasters.Glyph, side: CGFloat, resolve: () -> IconResolution) -> NSImage {
        IconRasters.shared.image(glyph, side: side, resolve: resolve)
    }
}
