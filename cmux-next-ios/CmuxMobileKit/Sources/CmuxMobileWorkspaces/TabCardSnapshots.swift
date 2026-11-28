#if os(iOS)
import CmuxMobileModel
import CryptoKit
import Observation
import SwiftUI
import UIKit

/// Whose tab a snapshot shows: the signed-in account, the Mac and the tab.
/// Each part is encoded on its own, so two identities never share a file.
public struct TabSnapshotKey: Hashable, Sendable {
    public let accountID: String
    public let macID: String
    public let tabID: String

    public init(accountID: String, macID: String, tabID: String) {
        self.accountID = accountID
        self.macID = macID
        self.tabID = tabID
    }

    var fileComponent: String {
        [accountID, macID, tabID].map(Self.encoded).joined(separator: "-")
    }

    /// One part of a file name: base64url without padding.
    static func encoded(_ part: String) -> String {
        Data(part.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What the phone last knew of a tab's card: which picture (by the hash of
/// its bytes), how large, when and from where. The picture itself is a blob
/// named by that hash, so a record can arrive before or after its bytes and
/// equal pictures are stored once.
public struct TabSnapshotRecord: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Drawn by this phone from a page it had loaded.
        case phone
        /// Sent by the Mac, which holds every open tab's last frame.
        case mac
    }

    public var thumbHash: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var capturedAtMs: Int64
    public var source: Source

    public init(thumbHash: String, pixelWidth: Int, pixelHeight: Int, capturedAtMs: Int64, source: Source) {
        self.thumbHash = thumbHash
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capturedAtMs = capturedAtMs
        self.source = source
    }
}

/// The last-known picture of every tab's card, on disk
/// (`Caches/cmux-mobile-tab-snapshots`): a record per tab and blobs by
/// content hash. A card of any kind shows its tab's picture from here when it
/// has nothing fresher, on a cold launch too, so the grid never opens on a
/// blank card for a tab the phone or the Mac has seen (Leo, 2026-11-22: "why
/// do we not have cached previews of the other tabs").
public struct TabSnapshotStore: Sendable {
    public let directory: URL
    /// Every write and delete holds it (tests hold it too, to queue two calls on it).
    let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public static var standard: TabSnapshotStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return TabSnapshotStore(directory: caches.appendingPathComponent("cmux-mobile-tab-snapshots", isDirectory: true))
    }

    /// The name a blob is stored and asked for by: SHA-256 of its bytes, hex.
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func recordURL(_ key: TabSnapshotKey) -> URL {
        directory.appendingPathComponent("v1-\(key.fileComponent)").appendingPathExtension("json")
    }

    func blobURL(_ hash: String) -> URL {
        directory.appendingPathComponent("blob-\(hash)")
    }

    public func record(_ key: TabSnapshotKey) -> TabSnapshotRecord? {
        guard let data = try? Data(contentsOf: recordURL(key)) else { return nil }
        return try? JSONDecoder().decode(TabSnapshotRecord.self, from: data)
    }

    public func hasBlob(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: blobURL(hash).path)
    }

    public func blob(_ hash: String) -> Data? {
        try? Data(contentsOf: blobURL(hash))
    }

    /// The tab's picture bytes, when both its record and its blob are here.
    public func picture(_ key: TabSnapshotKey) -> Data? {
        record(key).flatMap { blob($0.thumbHash) }
    }

    /// Stores bytes under their hash (a no-op when they are here already) and returns the hash.
    @discardableResult
    public func putBlob(_ data: Data) -> String {
        lock.withLock { writeBlob(data) }
    }

    /// Sets the tab's record unless a newer capture is stored. The blob the
    /// old record named goes when no other record names it.
    public func put(_ record: TabSnapshotRecord, for key: TabSnapshotKey) {
        lock.withLock { writeRecord(record, for: key) }
    }

    /// A picture captured now: its bytes and its record in one step, under one
    /// lock, so another tab's close or replacement never finds the new blob
    /// unnamed and deletes it before its record is written.
    public func save(_ data: Data, pixelWidth: Int, pixelHeight: Int, capturedAtMs: Int64,
                     source: TabSnapshotRecord.Source, for key: TabSnapshotKey) {
        lock.withLock {
            let hash = writeBlob(data)
            writeRecord(TabSnapshotRecord(thumbHash: hash, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                          capturedAtMs: capturedAtMs, source: source), for: key)
        }
    }

    /// Called under the lock.
    private func writeBlob(_ data: Data) -> String {
        let hash = Self.hash(data)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !hasBlob(hash) { try? data.write(to: blobURL(hash), options: .atomic) }
        return hash
    }

    /// Called under the lock.
    private func writeRecord(_ record: TabSnapshotRecord, for key: TabSnapshotKey) {
        let old = self.record(key)
        if let old, old.capturedAtMs > record.capturedAtMs { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: recordURL(key), options: .atomic) }
        if let old, old.thumbHash != record.thumbHash { removeBlobIfUnnamed(old.thumbHash) }
    }

    /// The tab closed: its record goes, and its blob when nothing else names it.
    public func remove(_ key: TabSnapshotKey) {
        lock.withLock {
            guard let old = record(key) else { return }
            try? FileManager.default.removeItem(at: recordURL(key))
            removeBlobIfUnnamed(old.thumbHash)
        }
    }

    /// The account signed out: its tabs' pictures go (the phone's records, its
    /// Macs' folders), and every blob no other account's record names.
    public func removeAccount(_ accountID: String) {
        let account = TabSnapshotKey.encoded(accountID) + "-"
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("v1-" + account) || file.lastPathComponent.hasPrefix("mac-" + account) {
                try? FileManager.default.removeItem(at: file)
            }
            let named = namedHashes()
            for file in files where file.lastPathComponent.hasPrefix("blob-") && !named.contains(String(file.lastPathComponent.dropFirst(5))) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Hashes named by any record (called under the lock).
    private func namedHashes() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var named: Set<String> = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(TabSnapshotRecord.self, from: data) {
                named.insert(record.thumbHash)
            }
        }
        return named
    }

    private func removeBlobIfUnnamed(_ hash: String) {
        if !namedHashes().contains(hash) { try? FileManager.default.removeItem(at: blobURL(hash)) }
    }
}

/// One tab's last-known picture, decoded: what its card reads. Observed per
/// tab, so a picture that arrives redraws only its own card.
@MainActor
@Observable
public final class TabSnapshotEntry {
    public fileprivate(set) var image: UIImage?
    /// The persisted picture dimensions arrive before its bytes finish decoding, so a card can
    /// reserve the same aspect on a cold launch.
    public fileprivate(set) var pixelWidth: Int = 0
    public fileprivate(set) var pixelHeight: Int = 0
    public var hasKnownPicture: Bool { pixelWidth > 0 && pixelHeight > 0 }
    public var knownPictureSize: CGSize? {
        guard hasKnownPicture else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
    /// When `image` was captured (0: unknown), so an older picture never replaces a newer one.
    @ObservationIgnored fileprivate var capturedAtMs: Int64 = 0
    /// The disk was asked for this tab's picture (once per launch, and again after a save or an eviction).
    @ObservationIgnored fileprivate var asked = false
    /// The picture last handed to `put` for this tab (held weakly: the page or raster owns it). The
    /// same picture again is already shown and on its way to disk, so it is not encoded twice.
    @ObservationIgnored fileprivate weak var kept: UIImage?
}

/// The last-known pictures in memory, over `TabSnapshotStore`: read by every
/// card kind, filled from disk off the main thread (decoded there too, ready
/// to draw), and written by whoever draws a tab's page: the agent card
/// rasterizer, a browser tab's snapshot, and later the Mac's stream.
/// Decoded pictures are bounded (`limit`, about 1.6 MB each at a column
/// card's resolution); the files are not.
@MainActor
public final class TabCardSnapshots {
    public static let shared = TabCardSnapshots()

    /// The signed-in account's id (`ShellModel` sets it). Without one nothing
    /// is read or written: a picture is never shown to another account.
    public var accountID: (@MainActor () -> String?)?
    public var store: TabSnapshotStore
    let limit: Int
    private var entries: [TabSnapshotKey: TabSnapshotEntry] = [:]
    /// Keys with a decoded picture, least recently shown first.
    private var resident: [TabSnapshotKey] = []
    /// Disk reads finished (tests).
    public private(set) var loads = 0
    /// Pictures written to disk (tests).
    public private(set) var saves = 0
    /// Pictures not written because their tab closed (or the account signed out) first (tests).
    public private(set) var dropped = 0
    /// Pictures `put` scaled and encoded off the main thread (tests): one per new picture.
    public private(set) var encodes = 0
    /// Pictures `put` was handed again unchanged (the one last kept for the tab), so not encoded (tests).
    public private(set) var unchanged = 0
    /// Every disk write and delete, in the order the main actor asked for them,
    /// so a tab's close always lands after a save it raced.
    private let disk = DispatchQueue(label: "cmux.mobile.tab-snapshots.disk", qos: .utility)
    #if DEBUG
    /// Tabs whose picture this launch wrote to disk (the UI tests' `TabCardFaceProbe`).
    public private(set) var savedTabs: Set<String> = []
    #endif

    public init(store: TabSnapshotStore = .standard, limit: Int = 40, memoryPressure: MemoryPressure = .shared) {
        self.store = store
        self.limit = limit
        memoryPressure.register(self) { [weak self] in self?.relieveMemoryPressure() }
    }

    public func key(macID: String, tabID: String) -> TabSnapshotKey? {
        guard let account = accountID?(), !account.isEmpty, !macID.isEmpty else { return nil }
        return TabSnapshotKey(accountID: account, macID: macID, tabID: tabID)
    }

    /// The tab's entry (made on first read). Reading it never touches the disk; `warm` does.
    public func entry(_ key: TabSnapshotKey) -> TabSnapshotEntry {
        if let entry = entries[key] { return entry }
        let entry = TabSnapshotEntry()
        entries[key] = entry
        return entry
    }

    /// Reads from disk the pictures of `keys` that are not in memory, in
    /// order (nearest the active tab first), off the main thread.
    public func warm(_ keys: [TabSnapshotKey]) {
        let store = store
        // `limit` bounds a tab list's warm; a card that appears warms its own key (`warm(key)`),
        // so a tab past the first `limit`, or one evicted since, is read when it shows.
        for key in keys.prefix(limit) {
            let entry = entry(key)
            guard entry.image == nil, !entry.asked else { continue }
            entry.asked = true
            Task.detached(priority: .userInitiated) { [weak self] in
                let newest = store.newestPicture(key)
                await self?.loadedMetadata(newest?.pixelWidth ?? 0, pixelHeight: newest?.pixelHeight ?? 0,
                                           capturedAtMs: newest?.capturedAtMs ?? 0, key: key)
                // A picture an earlier build saved as a placeholder (the cannot-draw mark, one solid
                // colour) is never shown; the card draws afresh instead.
                let image = newest.flatMap { UIImage(data: $0.data) }.flatMap { CardPictureGate.isPlaceholder($0) ? nil : $0 }?.preparingForDisplay()
                await self?.loaded(image, key, pixelWidth: newest?.pixelWidth ?? 0,
                                   pixelHeight: newest?.pixelHeight ?? 0,
                                   capturedAtMs: newest?.capturedAtMs ?? 0)
            }
        }
    }

    /// One card's picture, read from disk if it is not in memory: a card that appears asks for its
    /// own, so a tab past a list's first `limit` or one evicted since still shows its last picture.
    public func warm(_ key: TabSnapshotKey) {
        warm([key])
    }

    private func loadedMetadata(_ pixelWidth: Int, pixelHeight: Int, capturedAtMs: Int64, key: TabSnapshotKey) {
        guard let entry = entries[key], entry.image == nil else { return }
        guard pixelWidth > 0, pixelHeight > 0 else { return }
        entry.pixelWidth = pixelWidth
        entry.pixelHeight = pixelHeight
        entry.capturedAtMs = capturedAtMs
    }

    private func loaded(_ image: UIImage?, _ key: TabSnapshotKey, pixelWidth: Int, pixelHeight: Int,
                        capturedAtMs: Int64) {
        loads += 1
        guard let entry = entries[key], entry.image == nil else { return }
        if let image {
            entry.pixelWidth = pixelWidth > 0 ? pixelWidth : max(1, Int((image.size.width * image.scale).rounded()))
            entry.pixelHeight = pixelHeight > 0 ? pixelHeight : max(1, Int((image.size.height * image.scale).rounded()))
        }
        guard let image else { return }
        entry.image = image
        entry.capturedAtMs = capturedAtMs
        touch(key)
    }

    /// A page's picture drawn now: shown by the tab's card from here on, and
    /// written to disk (encoded off the main thread).
    /// `pixelWidth` (a whole page's snapshot): scaled to that width first,
    /// off the main thread, and shown once scaled.
    /// The picture last put for the tab, handed again (a page that drew nothing since, a chat
    /// whose card did not change), is neither shown again nor encoded: false then.
    @discardableResult
    public func put(_ image: UIImage, for key: TabSnapshotKey, pixelWidth: CGFloat = 0,
                    source: TabSnapshotRecord.Source = .phone, now: Date = Date()) -> Bool {
        // The tab is live while this entry is its entry: `remove` drops it (and what it kept).
        let live = entry(key)
        if live.kept === image {
            unchanged += 1
            // Let go from memory meanwhile: the disk has it.
            if live.image == nil { warm([key]) }
            return false
        }
        live.kept = image
        encodes += 1
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        if pixelWidth <= 0 { show(image, key, capturedAtMs: ms) }
        Task.detached(priority: .utility) { [weak self] in
            // A placeholder (`CardPictureGate`) is neither shown once scaled nor saved: the card's
            // last real picture stays.
            guard !CardPictureGate.isPlaceholder(image) else {
                if pixelWidth <= 0 { await self?.unshow(image, key) }
                return
            }
            var picture = image
            if pixelWidth > 0 {
                picture = TabCardSnapshots.downscaled(image, pixelWidth: pixelWidth)
                await self?.showScaled(picture, key, live, capturedAtMs: ms)
            }
            let data = picture.jpegData(compressionQuality: 0.8)
            await self?.encoded(data, key, live, pixelWidth: Int(picture.size.width * picture.scale),
                                pixelHeight: Int(picture.size.height * picture.scale), capturedAtMs: ms, source: source)
        }
        return true
    }

    /// A placeholder `put` showed at once goes again (the card's previous picture is gone from
    /// memory, so it reads the disk's, which the placeholder never replaced).
    private func unshow(_ image: UIImage, _ key: TabSnapshotKey) {
        guard let entry = entries[key], entry.image === image else { return }
        entry.image = nil
        entry.asked = false
        resident.removeAll { $0 == key }
        warm([key])
    }

    private func showScaled(_ image: UIImage, _ key: TabSnapshotKey, _ live: TabSnapshotEntry, capturedAtMs: Int64) {
        guard entries[key] === live else { return }
        show(image, key, capturedAtMs: capturedAtMs)
    }

    /// A picture encoded off the main thread: written unless its tab closed
    /// meanwhile, queued behind every earlier close and ahead of every later one.
    private func encoded(_ data: Data?, _ key: TabSnapshotKey, _ live: TabSnapshotEntry, pixelWidth: Int, pixelHeight: Int,
                         capturedAtMs: Int64, source: TabSnapshotRecord.Source) {
        guard entries[key] === live else {
            dropped += 1
            return
        }
        guard let data else { return }
        let store = store
        disk.async { [self] in
            store.save(data, pixelWidth: pixelWidth, pixelHeight: pixelHeight, capturedAtMs: capturedAtMs, source: source, for: key)
            Task { @MainActor in self.saved(key) }
        }
    }

    /// The Mac's picture of a tab (`MacTabCards`): shown unless the card has a newer one.
    public func show(macPicture image: UIImage, capturedAtMs: Int64, for key: TabSnapshotKey) {
        if let shown = entries[key], shown.image != nil, shown.capturedAtMs > capturedAtMs { return }
        show(image, key, capturedAtMs: capturedAtMs)
    }

    private func show(_ image: UIImage, _ key: TabSnapshotKey, capturedAtMs: Int64) {
        let entry = entry(key)
        entry.image = image
        entry.pixelWidth = max(1, Int((image.size.width * image.scale).rounded()))
        entry.pixelHeight = max(1, Int((image.size.height * image.scale).rounded()))
        entry.capturedAtMs = capturedAtMs
        entry.asked = true
        touch(key)
    }

    private func saved(_ key: TabSnapshotKey) {
        saves += 1
        #if DEBUG
        savedTabs.insert(key.tabID)
        #endif
    }

    /// The tab closed: its picture goes from memory and disk.
    public func remove(_ key: TabSnapshotKey) {
        entries[key]?.image = nil
        entries[key] = nil
        resident.removeAll { $0 == key }
        let store = store
        disk.async { store.remove(key) }
    }

    /// The account signed out: its pictures leave memory and the disk (they
    /// show its chats and pages), and a save still encoding is dropped.
    public func signedOut(accountID: String) {
        for entry in entries.values { entry.image = nil }
        entries = [:]
        resident = []
        guard !accountID.isEmpty else { return }
        let store = store
        disk.async { store.removeAccount(accountID) }
    }

    /// Runs after every disk write and delete asked for so far (tests).
    func diskSettled() async {
        let disk = disk
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in disk.async { done.resume() } }
    }

    private func touch(_ key: TabSnapshotKey) {
        resident.removeAll { $0 == key }
        resident.append(key)
        while resident.count > limit {
            let old = resident.removeFirst()
            entries[old]?.image = nil
            entries[old]?.asked = false
        }
    }

    /// A memory warning: decoded pictures go (the files stay, and `warm` reads them again).
    func relieveMemoryPressure() {
        for key in resident {
            entries[key]?.image = nil
            entries[key]?.asked = false
        }
        resident = []
    }

    /// `image` scaled to `pixelWidth` wide (a full page's snapshot stored at a card's resolution).
    public nonisolated static func downscaled(_ image: UIImage, pixelWidth: CGFloat) -> UIImage {
        let pixels = image.size.width * image.scale
        guard pixelWidth > 0, pixels > pixelWidth * 1.25 else { return image }
        let size = CGSize(width: pixelWidth, height: (image.size.height * image.scale * pixelWidth / pixels).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// A tab's last-known picture as its card shows it: full width, from the top.
/// Draws nothing while the tab has none.
struct TabSnapshotPicture: View {
    let image: UIImage?
    let pixelWidth: Int
    let pixelHeight: Int

    init(image: UIImage?, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var body: some View {
        GeometryReader { geo in
            let width = CGFloat(pixelWidth > 0 ? pixelWidth : Int(image?.size.width ?? 1))
            let height = CGFloat(pixelHeight > 0 ? pixelHeight : Int(image?.size.height ?? 1))
            Color.cmuxMobileBackground
                .frame(width: geo.size.width, height: geo.size.width * height / max(1, width), alignment: .top)
                .overlay(alignment: .top) {
                    if let image {
                        Image(uiImage: image).resizable().interpolation(.medium)
                            .frame(width: geo.size.width, height: geo.size.width * height / max(1, width))
                    }
                }
        }
        .accessibilityHidden(true)
    }
}
#endif
