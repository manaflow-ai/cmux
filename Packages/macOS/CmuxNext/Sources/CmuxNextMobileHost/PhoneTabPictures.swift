public import AppKit
public import CmuxNextCompat
import CmuxNextMobile
import CryptoKit
public import Foundation

/// Browser tabs' thumbnails and favicons for the phones' tab overview (`tabs`, tab-snapshots-v1): the leave picture a
/// page already takes (``offerThumbnail(_:tab:)``) and each favicon the page shows (``followFavicon(tab:favicon:)``) go
/// to `cmux-mobile-host` as a file in the app's own cache folder, named on a `tab_picture` line, keyed by the tab's
/// surface on this Mac's own daemon (the id hostd's `tabs` rows use). hostd keeps every rule (size cap, JPEG or PNG
/// only, a regular file; `tab_snapshots.rs`) and serves it; this only encodes and writes the bytes and skips a picture
/// whose bytes are the ones sent last for that tab and part. Nothing is captured for the phone alone, and nothing is
/// encoded or written while no phone is paired.
///
/// The app answers which surface a tab's pictures go out as (``init(iphone:folder:surface:encode:)``): none for a tab
/// of another machine or an incognito page, which send nothing.
///
/// Files are named by their content, so a write never changes a file hostd may be reading: a newer picture is a new
/// file, and the one before it goes once the newer line is sent. A tab's files go when it closes (``forget(tab:)``).
@MainActor
public final class PhoneTabPictures {
    public enum Part: String, Sendable {
        case thumb
        case favicon
    }

    /// A picture cut to fit a size and encoded (a JPEG, or a PNG when it has transparent pixels) at a JPEG quality,
    /// with its pixel size; nil when it cannot be encoded. Runs off the main actor.
    public typealias Encode = @Sendable (_ image: CGImage, _ fit: CGSize, _ quality: Double) -> (data: Data, width: Int, height: Int)?

    /// The widest thumbnail a phone gets, and its JPEG quality.
    nonisolated static let thumbnailWidth: CGFloat = 576
    nonisolated static let thumbnailQuality = 0.7

    private nonisolated struct Sent: Sendable {
        var hash: String
        var file: URL
    }

    private weak var iphone: IPhoneHostService?
    private let folder: URL
    /// The daemon surface tab `key`'s pictures go out as: its surface on this Mac's own daemon showing a page that
    /// is not incognito; nil sends nothing.
    private let surface: @MainActor (_ key: String) -> UInt64?
    private let encode: Encode
    /// The picture sent last of each surface's part.
    private var sent: [String: Sent] = [:]
    /// Bumped by every offer and forget of a surface's part: an older write that lands late is dropped.
    private var turns: [String: UInt64] = [:]
    /// The surface each tab's pictures went out as, by the app's tab key.
    private var surfaces: [String: UInt64] = [:]
    /// Each live page's favicon follow, by the app's tab key.
    private var favicons: [String: Task<Void, Never>] = [:]

    public init(iphone: IPhoneHostService, folder: URL = BuildStatePaths.current.phoneTabPicturesCache,
                surface: @escaping @MainActor (_ key: String) -> UInt64?, encode: @escaping Encode) {
        self.iphone = iphone
        self.folder = folder
        self.surface = surface
        self.encode = encode
    }

    /// Whether a phone can get the pictures: iPhone connections are on and one is paired. Until then nothing is
    /// encoded or written.
    public var wanted: Bool {
        guard let iphone else { return false }
        return iphone.allowed && !(iphone.paired?.devices.isEmpty ?? true)
    }

    /// The surface tab `key`'s pictures go out as now, nil while no phone wants them.
    private func phoneSurface(_ key: String) -> UInt64? {
        guard wanted, let surface = surface(key) else { return nil }
        return surface
    }

    /// A leave picture of tab `key`'s page (one that is not blank), cut to ``thumbnailWidth`` and encoded off the
    /// main actor.
    public func offerThumbnail(_ image: CGImage, tab key: String) {
        guard let surface = phoneSurface(key) else { return }
        surfaces[key] = surface
        let encode = encode, fit = CGSize(width: Self.thumbnailWidth, height: .greatestFiniteMagnitude)
        let quality = Self.thumbnailQuality
        // task-owner: one encode per leave picture; ends on its own.
        Task { [weak self] in
            let encoded = await Task.detached(priority: .utility) { encode(image, fit, quality) }.value
            guard let self, let encoded else { return }
            self.offer(surface: surface, part: .thumb, data: encoded.data, width: encoded.width, height: encoded.height)
        }
    }

    /// Follows the favicon of tab `key`'s page (`favicon` reads it, observably) for the phones while it is the
    /// tab's page: ``stopFavicon(tab:)`` stops it when the page leaves the tab.
    public func followFavicon(tab key: String, favicon: @escaping @MainActor @Sendable () -> NSImage?) {
        favicons.removeValue(forKey: key)?.cancel()
        // task-owner: favicons[key]; event-driven (Observation), cancelled by stopFavicon(tab:) when the page leaves.
        favicons[key] = Task { [weak self] in
            let icons = ObservationStream { () -> ObjectIdentifier? in favicon().map(ObjectIdentifier.init) }
            for await icon in icons {
                guard icon != nil, let self, let image = favicon(), let surface = self.phoneSurface(key),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                self.surfaces[key] = surface
                let png = await Task.detached(priority: .utility) {
                    NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
                }.value
                guard !Task.isCancelled, let png else { continue }
                self.offer(surface: surface, part: .favicon, data: png, width: cgImage.width, height: cgImage.height)
            }
        }
    }

    /// Tab `key`'s page left it: its favicon is no longer followed.
    public func stopFavicon(tab key: String) {
        favicons.removeValue(forKey: key)?.cancel()
    }

    /// Tab `key` closed: its pictures leave the phones' cache folder and the host's replay.
    public func forget(tab key: String) {
        guard let surface = surfaces.removeValue(forKey: key) else { return }
        forget(surface: surface)
    }

    /// `data` (a JPEG or PNG of `width` x `height` pixels) as `part` of the tab of daemon surface `surface`: written
    /// and handed to hostd unless it is the picture sent last for that tab and part.
    func offer(surface: UInt64, part: Part, data: Data, width: Int, height: Int) {
        guard wanted, !data.isEmpty else { return }
        let key = "\(surface)-\(part.rawValue)"
        let turn = (turns[key] ?? 0) &+ 1
        turns[key] = turn
        let folder = folder, ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        // task-owner: one write per picture; ends on its own (a file write), dropped below when a newer one started.
        Task { [weak self] in
            let written = await Task.detached(priority: .utility) { () -> Sent? in
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let file = folder.appendingPathComponent("\(key)-\(hash.prefix(16)).\(ext)")
                if FileManager.checked.fileExists(atPath: file.path) { return Sent(hash: hash, file: file) }
                do {
                    try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.blockingWrite(to: file, options: .atomic)
                } catch {
                    return nil
                }
                return Sent(hash: hash, file: file)
            }.value
            guard let self, let written else { return }
            guard self.turns[key] == turn else {
                if self.sent[key]?.file != written.file { Self.remove([written.file]) }
                return
            }
            let previous = self.sent[key]
            guard previous?.hash != written.hash else { return }
            self.sent[key] = written
            let line = MobileHostLaunch.tabPictureLine(surface: surface, part: part.rawValue, path: written.file.path,
                                                       width: width, height: height, capturedAtMs: capturedAtMs)
            await self.iphone?.setTabPicture(surface: surface, part: part.rawValue, line: line)
            if let previous, previous.file != written.file { Self.remove([previous.file]) }
        }
    }

    /// The tab of `surface` closed: its files go and no new hostd gets its pictures.
    func forget(surface: UInt64) {
        var files: [URL] = []
        for part in [Part.thumb, .favicon] {
            let key = "\(surface)-\(part.rawValue)"
            turns[key] = (turns[key] ?? 0) &+ 1
            if let file = sent.removeValue(forKey: key)?.file { files.append(file) }
        }
        if !files.isEmpty { Self.remove(files) }
        let iphone = iphone
        // task-owner: one hop to the supervisor actor; ends on its own.
        Task { await iphone?.forgetTabPictures(surface: surface) }
    }

    private nonisolated static func remove(_ files: [URL]) {
        // task-owner: deletes this class's own files; ends on its own.
        Task.detached(priority: .utility) {
            for file in files { try? FileManager.checked.removeItem(at: file) }
        }
    }
}

extension IPhoneHostService {
    /// A browser tab's picture line for the phones (``PhoneTabPictures``): one hop to the supervisor, which keeps the
    /// newest of each tab's part for each new hostd.
    func setTabPicture(surface: UInt64, part: String, line: Data) async {
        await supervisor.setTabPicture(surface: surface, part: part, line: line)
    }

    /// The tab of `surface` closed: no new hostd gets its pictures.
    func forgetTabPictures(surface: UInt64) async {
        await supervisor.forgetTabPictures(surface: surface)
    }
}
