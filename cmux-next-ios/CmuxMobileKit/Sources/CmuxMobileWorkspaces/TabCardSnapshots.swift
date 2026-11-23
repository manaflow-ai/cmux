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
        [accountID, macID, tabID].map { Data($0.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") }.joined(separator: "-")
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
    private let lock = NSLock()

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
        let hash = Self.hash(data)
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !hasBlob(hash) { try? data.write(to: blobURL(hash), options: .atomic) }
        }
        return hash
    }

    /// Sets the tab's record unless a newer capture is stored. The blob the
    /// old record named goes when no other record names it.
    public func put(_ record: TabSnapshotRecord, for key: TabSnapshotKey) {
        lock.withLock {
            let old = self.record(key)
            if let old, old.capturedAtMs > record.capturedAtMs { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(record) { try? data.write(to: recordURL(key), options: .atomic) }
            if let old, old.thumbHash != record.thumbHash { removeBlobIfUnnamed(old.thumbHash) }
        }
    }

    /// A picture captured now: its bytes and its record in one step.
    public func save(_ data: Data, pixelWidth: Int, pixelHeight: Int, capturedAtMs: Int64,
                     source: TabSnapshotRecord.Source, for key: TabSnapshotKey) {
        let hash = putBlob(data)
        put(TabSnapshotRecord(thumbHash: hash, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                              capturedAtMs: capturedAtMs, source: source), for: key)
    }

    /// The tab closed: its record goes, and its blob when nothing else names it.
    public func remove(_ key: TabSnapshotKey) {
        lock.withLock {
            guard let old = record(key) else { return }
            try? FileManager.default.removeItem(at: recordURL(key))
            removeBlobIfUnnamed(old.thumbHash)
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
    /// When `image` was captured (0: unknown), so an older picture never replaces a newer one.
    @ObservationIgnored fileprivate var capturedAtMs: Int64 = 0
    /// The disk was asked for this tab's picture (once per launch, and again after a save or an eviction).
    @ObservationIgnored fileprivate var asked = false
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
        for key in keys.prefix(limit) {
            let entry = entry(key)
            guard entry.image == nil, !entry.asked else { continue }
            entry.asked = true
            Task.detached(priority: .userInitiated) { [weak self] in
                let newest = store.newestPicture(key)
                let image = newest.flatMap { UIImage(data: $0.data) }?.preparingForDisplay()
                await self?.loaded(image, key, capturedAtMs: newest?.capturedAtMs ?? 0)
            }
        }
    }

    private func loaded(_ image: UIImage?, _ key: TabSnapshotKey, capturedAtMs: Int64) {
        loads += 1
        guard let image, let entry = entries[key], entry.image == nil else { return }
        entry.image = image
        entry.capturedAtMs = capturedAtMs
        touch(key)
    }

    /// A page's picture drawn now: shown by the tab's card from here on, and
    /// written to disk (encoded off the main thread).
    /// `pixelWidth` (a whole page's snapshot): scaled to that width first,
    /// off the main thread, and shown once scaled.
    public func put(_ image: UIImage, for key: TabSnapshotKey, pixelWidth: CGFloat = 0,
                    source: TabSnapshotRecord.Source = .phone, now: Date = Date()) {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        if pixelWidth <= 0 { show(image, key, capturedAtMs: ms) }
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            var picture = image
            if pixelWidth > 0 {
                picture = TabCardSnapshots.downscaled(image, pixelWidth: pixelWidth)
                await self?.show(picture, key, capturedAtMs: ms)
            }
            guard let data = picture.jpegData(compressionQuality: 0.8) else { return }
            store.save(data, pixelWidth: Int(picture.size.width * picture.scale),
                       pixelHeight: Int(picture.size.height * picture.scale), capturedAtMs: ms, source: source, for: key)
            await self?.saved(key)
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
        Task.detached(priority: .utility) { store.remove(key) }
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
    let image: UIImage

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image).resizable().interpolation(.medium)
                .frame(width: geo.size.width, height: geo.size.width * image.size.height / max(1, image.size.width))
        }
        .accessibilityHidden(true)
    }
}
#endif
