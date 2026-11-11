public import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A PNG for a picture the pasteboard holds only as TIFF, made before Chromium reads it
/// (https://github.com/manaflow-ai/cmux/issues/41016).
///
/// Chromium's macOS paste reads `public.png`. When the pasteboard holds the picture as TIFF only
/// (Preview, Safari's Copy Image and many other apps write it so), Chromium decodes the TIFF and
/// encodes the whole bitmap as PNG with ImageIO's default filters, while the page waits on the read:
/// 300 ms and more for a 5K screenshot, most of it in the PNG writer's filter search. The same encode
/// with no filter search takes about a third of that and makes a file no bigger, so the page asks
/// the host to add that PNG first and Chromium reads it as it is.
///
/// The pasteboard keeps everything it held: each item gets back every type with its own bytes
/// (the writer's `org.nspasteboard.source` too) and the PNG beside the TIFF. When a type cannot be
/// read, or the pasteboard changed meanwhile, nothing is written and Chromium pastes as before.
public nonisolated struct PastedImagePNG: Sendable {
    /// One pasteboard item's types and their bytes, in the item's order.
    struct Item: Sendable {
        var entries: [(type: String, data: Data)]
    }

    public init() {}

    /// Whether a pasteboard with `types` holds a picture as TIFF and no PNG: Finder's copied files
    /// (whose TIFF is their icon) and text with a picture are left to Chromium.
    public func needsPNG(types: [String]) -> Bool {
        let types = Set(types)
        return types.contains(UTType.tiff.identifier) && !types.contains(UTType.png.identifier)
            && !types.contains(UTType.fileURL.identifier)
    }

    /// Whether `pasteboard` needs a PNG (``needsPNG(types:)``): only its types, no bytes read.
    @MainActor public func needsPNG(_ pasteboard: NSPasteboard) -> Bool {
        needsPNG(types: pasteboard.types?.map(\.rawValue) ?? [])
    }

    /// `tiff` as a PNG, with no filter search: nil when ImageIO cannot read it.
    public func png(fromTIFF tiff: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        // IMAGEIO_PNG_FILTER_NONE: every row as it is. The default tries each filter on each row.
        let options = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: 0x08]] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Adds a PNG beside the TIFF of the pasteboard named `name`, off the main thread, as Chromium
    /// reads the pasteboard off it too. `changeCount` is the pasteboard's when the paste began: a
    /// pasteboard that changed since is left as it is. Returns the change count after the write,
    /// or nil when nothing was written.
    @concurrent public func addPNG(pasteboard name: NSPasteboard.Name, changeCount: Int) async -> Int? {
        let pasteboard = NSPasteboard(name: name)
        guard pasteboard.changeCount == changeCount, let read = pasteboard.pasteboardItems else { return nil }
        var items: [Item] = []
        var made = false
        for item in read {
            var entries: [(type: String, data: Data)] = []
            for type in item.types {
                // A type whose bytes do not come back would be lost: write nothing.
                guard let data = item.data(forType: type) else { return nil }
                entries.append((type.rawValue, data))
            }
            if !made, let tiff = entries.first(where: { $0.type == UTType.tiff.identifier })?.data {
                guard let png = png(fromTIFF: tiff) else { return nil }
                entries.append((UTType.png.identifier, png))
                made = true
            }
            items.append(Item(entries: entries))
        }
        guard made, pasteboard.changeCount == changeCount else { return nil }
        let written = items.map { item in
            let written = NSPasteboardItem()
            for entry in item.entries { written.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type)) }
            return written
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(written) else { return nil }
        return pasteboard.changeCount
    }
}

/// Holds a Cmd-V into a cmux page while ``PastedImagePNG`` adds the PNG, then lets the same key go
/// on: Chromium reads the PNG instead of encoding one. One per engine, on the main actor.
@MainActor
public final class PastedImagePNGHold {
    /// The change count of the pasteboard this last held a paste for: the paste that goes on after
    /// it (or after a conversion that did not happen) is never held again.
    private var held: Int?
    private let converter = PastedImagePNG()

    public init() {}

    /// Whether to hold this paste: the general pasteboard holds a picture as TIFF only, and this has
    /// not held a paste for its contents. When true, `resume` runs once the PNG is there (or could
    /// not be made), on the main actor, and the caller keeps the key from Chromium until then.
    public func hold(_ pasteboard: NSPasteboard = .general, resume: @escaping @MainActor (_ added: Bool) -> Void) -> Bool {
        let changeCount = pasteboard.changeCount
        guard held != changeCount, converter.needsPNG(pasteboard) else { return false }
        held = changeCount
        let name = pasteboard.name
        Task {
            let written = await converter.addPNG(pasteboard: name, changeCount: changeCount)
            if let written { held = written }
            resume(written != nil)
        }
        return true
    }
}
