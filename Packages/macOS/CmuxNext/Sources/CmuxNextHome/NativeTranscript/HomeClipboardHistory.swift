import AppKit
public import CmuxNextSettings
import CmuxNextHomeModel
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
/// One instance per app, made at the composition root (`HomeService.clipboardHistory`) and given to
/// each Home composer (``HomeNativeTranscriptView/clipboardHistory``); the app's own activation
/// observer (`HomeService.observeActivation`) calls ``appDidBecomeActive()``.
///
/// Pictures get a small thumbnail made off the main thread for the menu row; the row shows a
/// generic picture glyph until it is ready.
@MainActor
public final class HomeClipboardHistory {
    /// Whether the person allows the history (`home.clipboardHistory`); read at every event point.
    /// Off until the app wires the setting (fail closed).
    var isEnabled: () -> Bool = { false }
    private(set) var log = HomeClipboardLog()
    private let pasteboard: any HomeClipboardSource
    private var thumbnails: [Int: NSImage] = [:]

    init(pasteboard: any HomeClipboardSource = NSPasteboard.general) {
        self.pasteboard = pasteboard
    }

    /// The app's history over the general pasteboard, on while `home.clipboardHistory` is (read at
    /// each event point). Nothing is read until the settings file has loaded: the empty snapshot
    /// holds the default, on.
    public convenience init(settings: @escaping () -> SettingsController?) {
        self.init()
        isEnabled = {
            guard let settings = settings(), settings.loadCount > 0 else { return false }
            return settings.snapshot.homeClipboardHistory
        }
    }

    /// cmux became the active app: reads what was copied elsewhere, where macOS reads without asking.
    public func appDidBecomeActive() { recordIfAllowed(backgroundRead: true) }

    /// The newest `limit` copies, after reading the pasteboard (the + menu is opening). Empty when off.
    func recent(_ limit: Int) -> [HomeClipboardEntry] {
        recordIfAllowed(backgroundRead: false)
        return isEnabled() ? log.newest(limit) : []
    }

    /// A picture row's thumbnail, once made.
    func thumbnail(for entry: HomeClipboardEntry) -> NSImage? { thumbnails[entry.id] }

    /// Reads the pasteboard when the setting allows it and it changed since the last read.
    /// `backgroundRead` (an activation, not a click): skipped unless the system reads without
    /// asking (``HomeClipboardSource/readsWithoutAsking``), so no pasteboard-privacy prompt ever
    /// comes from switching to cmux.
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
            await self?.keepThumbnail(image, id: id)
        }
    }

    /// Keeps a decoded thumbnail while its entry is still in the history (one small NSImage).
    private func keepThumbnail(_ image: CGImage, id: Int) {
        guard log.entries.contains(where: { $0.id == id }) else { return }
        let scale = Self.thumbnailSide / CGFloat(max(max(image.width, image.height), 1))
        thumbnails[id] = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
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

/// When an activation may read the pasteboard. Before macOS 15.4 there is no pasteboard privacy:
/// always. From 15.4 on, `.default` is the prompting behavior ("ask on programmatic access",
/// NSPasteboard.h) once Apple enforces it, so only `.alwaysAllow` (the person allowed cmux) reads
/// without asking, unless the Debug Settings tunable `home.clipboardHistory.readAtDefaultAccess`
/// also lets `.default` read (dogfood on systems that do not enforce it yet). `.alwaysDeny` and
/// any behavior a later SDK adds never read at activation.
nonisolated enum HomeClipboardAccess: String, Sendable, Equatable, Encodable {
    case noPrivacy, alwaysAllow, `default`, alwaysDeny

    /// `compose.clipboard.readsWithoutAsking` (cmux-home-rules `compose/clipboard.rs`); a failed call never reads.
    func readsWithoutAsking(defaultReads: Bool) -> Bool {
        do { return try HomeRules.call("compose.clipboard.readsWithoutAsking", AccessInput(access: self, defaultReads: defaultReads)) } catch { assertionFailure("\(error)"); return false }
    }

    private nonisolated struct AccessInput: Encodable { var access: HomeClipboardAccess, defaultReads: Bool }
}

extension NSPasteboard: HomeClipboardSource {
    var contents: any HomePasteboardContents { self }

    var readsWithoutAsking: Bool {
        access.readsWithoutAsking(defaultReads: HomeTunables.clipboardReadAtDefaultAccess.value)
    }

    private var access: HomeClipboardAccess {
        guard #available(macOS 15.4, *) else { return .noPrivacy }
        switch accessBehavior {
        case .alwaysAllow: return .alwaysAllow
        case .default: return .default
        default: return .alwaysDeny
        }
    }
}
