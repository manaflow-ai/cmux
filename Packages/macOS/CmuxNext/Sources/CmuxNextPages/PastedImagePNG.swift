public import AppKit
import CmuxNextWakeups
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
/// Only a plain picture is touched: one item that holds the TIFF and a few small types beside it
/// (its URL, a caption, the writer's `org.nspasteboard.source`), all written back with their own
/// bytes and the PNG added. Anything else is left to Chromium as it was: a pasteboard a password
/// manager or another device wrote (concealed, transient, Universal Clipboard), more than one item,
/// or a type another app would have to make on demand (a document's other formats, a file promise),
/// which reading it here would force. When a type cannot be read, or the pasteboard changed
/// meanwhile, nothing is written.
public nonisolated struct PastedImagePNG: Sendable {
    /// One pasteboard item's types and their bytes, in the item's order.
    nonisolated struct Item: Sendable {
        var entries: [(type: String, data: Data)]
    }

    public init() {}

    /// The types a plain picture's item may hold beside its TIFF: each small, written with the TIFF.
    static let plainPictureTypes: Set<String> = [
        "public.tiff", "NeXT TIFF v4.0 pasteboard type", "org.nspasteboard.source",
        "public.url", "public.url-name", "Apple URL pasteboard type", "public.utf8-plain-text", "NSStringPboardType",
        "public.html", "Apple HTML pasteboard type",
    ]

    /// Whether a pasteboard of `items` (each item's types) holds one plain picture as TIFF and no
    /// PNG: one item, every type a plain picture's (`plainPictureTypes`, or a type the system
    /// derives from them, `dyn.`). Finder's copied files (whose TIFF is their icon), concealed and
    /// transient contents, Universal Clipboard and a document's own formats are left to Chromium.
    public func needsPNG(items: [[String]]) -> Bool {
        guard items.count == 1, let types = items.first.map(Set.init), types.contains(UTType.tiff.identifier) else {
            return false
        }
        return types.allSatisfy { Self.plainPictureTypes.contains($0) || $0.hasPrefix("dyn.") }
    }

    /// Whether `pasteboard` needs a PNG (``needsPNG(items:)``): only its types, no bytes read.
    @MainActor public func needsPNG(_ pasteboard: NSPasteboard) -> Bool {
        needsPNG(items: (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) })
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
        guard pasteboard.changeCount == changeCount, let read = pasteboard.pasteboardItems,
              needsPNG(items: read.map { $0.types.map(\.rawValue) }) else { return nil }
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

/// Holds a Cmd-V into a cmux page while ``PastedImagePNG`` adds the PNG, then lets it go on:
/// Chromium reads the PNG instead of encoding one. One per engine, on the main actor.
@MainActor
public final class PastedImagePNGHold {
    /// The change count of the pasteboard this last held a paste for: the paste that goes on after
    /// it (or after a conversion that did not happen) is never held again.
    private var held: Int?
    /// The pastes waiting for the PNG being made, in order: a second Cmd-V (or a repeat) during the
    /// hold waits too, so none reads the pasteboard while it is being written.
    private var waiting: [@MainActor (_ added: Bool) -> Void] = []
    /// The conversion `waiting` waits for; one that ends after its deadline resumes nothing again.
    private var round = 0
    private let converter = PastedImagePNG()
    /// The deadline's timer: it wakes only while a paste waits.
    private let timer: DemandTimer
    /// How long a paste waits for its PNG. Reading the picture asks the app that copied it, which
    /// may be slow to answer or hung: past this the paste goes on and Chromium reads the TIFF, as
    /// before; every Cmd-V into a cmux page would wait behind it otherwise.
    private let deadline: Duration

    public init(clock: any Clock<Duration> = ContinuousClock(), deadline: Duration = .seconds(1)) {
        timer = DemandTimer(owner: "pasted-image-png", clock: clock)
        self.deadline = deadline
    }

    /// Whether to hold this paste: the general pasteboard holds a plain picture as TIFF only
    /// (``PastedImagePNG/needsPNG(_:)``) and this has not held a paste for its contents, or a PNG
    /// is being made now. When true, `resume` runs once the PNG is there (or could not be made),
    /// on the main actor, and the caller keeps the key from Chromium until then.
    public func hold(_ pasteboard: NSPasteboard = .general, resume: @escaping @MainActor (_ added: Bool) -> Void) -> Bool {
        if !waiting.isEmpty {
            waiting.append(resume)
            return true
        }
        let changeCount = pasteboard.changeCount
        guard held != changeCount, converter.needsPNG(pasteboard) else { return false }
        held = changeCount
        waiting = [resume]
        round += 1
        let this = round
        let name = pasteboard.name
        Task {
            let written = await converter.addPNG(pasteboard: name, changeCount: changeCount)
            if let written { held = written }
            finish(this, added: written != nil)
        }
        timer.schedule(after: deadline) { @MainActor [weak self] in self?.finish(this, added: false) }
        return true
    }

    /// Resumes the pastes waiting for conversion `this`, once: its PNG was written (`added`), or
    /// could not be, or its deadline passed first.
    private func finish(_ this: Int, added: Bool) {
        guard this == round, !waiting.isEmpty else { return }
        timer.cancel()
        let resumed = waiting
        waiting = []
        for each in resumed { each(added) }
    }
}
