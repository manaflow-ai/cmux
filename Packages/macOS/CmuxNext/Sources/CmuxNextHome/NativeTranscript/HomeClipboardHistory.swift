import AppKit
import ImageIO

/// The Chief's clipboard history for the + menu (`home.clipboardHistory`, on by default): what
/// the person copied recently, text and pictures, kept in memory only and never written to disk
/// or sent anywhere.
///
/// The pasteboard has no change notification, and cmux never polls, so the history reads the
/// general pasteboard only at event points: when cmux becomes the active app (what was copied in
/// another app before coming back) and when the + menu opens (what was copied in cmux). A read
/// happens only when the pasteboard's `changeCount` moved; a copy made and replaced while cmux
/// stayed in the background is never seen. Off, nothing is read and the history is dropped at
/// the next event point.
///
/// Pictures get a small thumbnail made off the main thread for the menu row; the row shows a
/// generic picture glyph until it is ready.
@MainActor
final class HomeClipboardHistory {
    static let shared = HomeClipboardHistory()

    /// Whether the person allows the history (`home.clipboardHistory`); read at every event point.
    var isEnabled: () -> Bool = { true }
    private(set) var log = HomeClipboardLog()
    private let pasteboard: any HomeClipboardSource
    private var thumbnails: [Int: NSImage] = [:]
    private var activation: (any NSObjectProtocol)?

    init(pasteboard: any HomeClipboardSource = NSPasteboard.general) {
        self.pasteboard = pasteboard
    }

    /// Starts reading at each activation of cmux (once; later calls do nothing).
    func start() {
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            // task-owner: one read per activation, on the main actor.
            Task { @MainActor in self?.recordIfAllowed(backgroundRead: true) }
        }
    }

    /// The newest `limit` copies, after reading the pasteboard (the + menu is opening). Empty when off.
    func recent(_ limit: Int) -> [HomeClipboardEntry] {
        recordIfAllowed(backgroundRead: false)
        return isEnabled() ? log.newest(limit) : []
    }

    /// A picture row's thumbnail, once made.
    func thumbnail(for entry: HomeClipboardEntry) -> NSImage? { thumbnails[entry.id] }

    /// Reads the pasteboard when the setting allows it and it changed since the last read.
    /// `backgroundRead` (an activation, not a click): skipped where the system would ask the
    /// person first (pasteboard privacy set to Ask or Deny for cmux), so no prompt ever comes
    /// from switching to cmux.
    func recordIfAllowed(backgroundRead: Bool) {
        guard isEnabled() else {
            if !log.entries.isEmpty || log.lastChangeCount != nil { log.clear(); thumbnails.removeAll() }
            return
        }
        if backgroundRead, !pasteboard.readsWithoutAsking { return }
        let count = pasteboard.changeCount
        guard log.needsRead(changeCount: count) else { return }
        let content = HomeClipboardLog.content(of: pasteboard.contents)
        guard log.record(content, changeCount: count) else { return }
        let kept = Set(log.entries.map(\.id))
        thumbnails = thumbnails.filter { kept.contains($0.key) }
        if case let .image(data, _)? = content { makeThumbnail(id: count, data: data) }
    }

    /// Side of a row's thumbnail in points (a menu row's image).
    static let thumbnailSide: CGFloat = 32

    private func makeThumbnail(id: Int, data: Data) {
        let pixels = Int(Self.thumbnailSide * 2)
        // task-owner: one decode per copied picture; the result is dropped if the entry has gone.
        Task.detached(priority: .utility) { [weak self] in
            guard let image = Self.thumbnailImage(data, maxPixels: pixels) else { return }
            await MainActor.run {
                guard let self, self.log.entries.contains(where: { $0.id == id }) else { return }
                let side = Self.thumbnailSide
                let scale = side / CGFloat(max(image.width, image.height, 1))
                self.thumbnails[id] = NSImage(
                    cgImage: image, size: NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
            }
        }
    }

    /// A downscaled decode (ImageIO's thumbnail path: it never decodes the full picture).
    nonisolated private static func thumbnailImage(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The pasteboard the history reads: the general pasteboard in the app, a value in tests.
@MainActor
protocol HomeClipboardSource: AnyObject {
    var changeCount: Int { get }
    /// The contents to read (read only after `changeCount` moved).
    var contents: any HomePasteboardContents { get }
    /// Whether a read outside a click shows no system prompt (pasteboard privacy allows it).
    var readsWithoutAsking: Bool { get }
}

extension NSPasteboard: HomeClipboardSource {
    var contents: any HomePasteboardContents { self }

    var readsWithoutAsking: Bool {
        if #available(macOS 15.4, *) {
            switch accessBehavior {
            case .ask, .alwaysDeny: return false
            default: return true
            }
        }
        return true
    }
}
