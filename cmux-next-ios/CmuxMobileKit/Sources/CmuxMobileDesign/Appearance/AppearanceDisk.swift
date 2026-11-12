import CryptoKit
import Foundation

/// The phone's appearance files (PROTOCOL.md "Appearance", Phone):
/// one snapshot per Mac (`Application Support/appearance/<macId>.json`) and
/// the background images by hash (`appearance/assets/<sha256>.jpg`, at most
/// ``assetLimit`` kept, least recently used dropped). An image the phone holds
/// is never fetched again. Thread-safe: every call holds one lock for its file
/// work (each is a small read or write).
public final class CmuxMobileAppearanceDisk: @unchecked Sendable {
    public static let standard = CmuxMobileAppearanceDisk(
        root: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("appearance", isDirectory: true),
        defaults: .standard)

    /// Images kept at most.
    public static let assetLimit = 8
    /// The Mac whose snapshot "Match my Mac" draws: the one most recently connected.
    public static let lastMacKey = "cmuxMobile.appearance.lastMacID"

    public let root: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var lastStamp = Date.distantPast

    public init(root: URL, defaults: UserDefaults) {
        self.root = root
        self.defaults = defaults
    }

    private var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }

    /// The Mac most recently connected (whose snapshot the phone matches).
    public var lastMacID: String? {
        get { defaults.string(forKey: Self.lastMacKey) }
        set { defaults.set(newValue, forKey: Self.lastMacKey) }
    }

    /// A file name for a Mac id: its characters that are safe in a path, else its hash.
    static func fileName(macID: String) -> String {
        let safe = macID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        if safe, !macID.isEmpty, macID.count <= 128 { return macID }
        return SHA256.hash(data: Data(macID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func snapshotURL(macID: String) -> URL { root.appendingPathComponent("\(Self.fileName(macID: macID)).json") }

    /// The stored snapshot of `macID`, if any.
    public func snapshot(macID: String) -> CmuxMobileAppearanceSnapshot? {
        lock.withLock {
            guard let data = try? Data(contentsOf: snapshotURL(macID: macID)) else { return nil }
            return CmuxMobileAppearanceSnapshot.decode(data)
        }
    }

    /// Stores `snapshot` as `macID`'s; `makeCurrent` (a Mac that just
    /// connected) makes it the Mac the phone matches. Answers whether it
    /// differs from what was stored.
    @discardableResult
    public func store(_ snapshot: CmuxMobileAppearanceSnapshot, macID: String, makeCurrent: Bool = true) -> Bool {
        lock.withLock {
            let url = snapshotURL(macID: macID)
            let data = snapshot.encoded()
            let changed = (try? Data(contentsOf: url)) != data
            if changed {
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
            if makeCurrent { defaults.set(macID, forKey: Self.lastMacKey) }
            return changed
        }
    }

    /// The phone's own Personalization choice.
    public var personalization: CmuxMobilePersonalization {
        get { CmuxMobilePersonalization.load(defaults) }
        set { newValue.save(defaults) }
    }

    // MARK: - The phone's own picture

    private var phoneImages: URL { root.appendingPathComponent("phone", isDirectory: true) }

    /// Keeps `data` (a JPEG the phone made from a Photos pick) as the phone's
    /// own background, replacing the one before; answers its hash. Never
    /// counted in, or dropped by, the Macs' image cache.
    public func storePhoneImage(_ data: Data) -> String? {
        let sha = Self.sha256(data)
        return lock.withLock {
            let fm = FileManager.default
            try? fm.createDirectory(at: phoneImages, withIntermediateDirectories: true)
            for old in (try? fm.contentsOfDirectory(at: phoneImages, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: old)
            }
            return (try? data.write(to: phoneImages.appendingPathComponent("\(sha).jpg"), options: .atomic)) != nil ? sha : nil
        }
    }

    /// The phone's own background with `sha256`, if it holds it.
    public func phoneImageURL(sha256: String) -> URL? {
        guard Self.isHash(sha256) else { return nil }
        let url = phoneImages.appendingPathComponent("\(sha256).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Images

    func assetFile(sha256: String) -> URL { assets.appendingPathComponent("\(sha256).jpg") }

    /// The image with `sha256` when the phone holds it (and marks it used).
    public func assetURL(sha256: String) -> URL? {
        guard Self.isHash(sha256) else { return nil }
        return lock.withLock {
            let url = assetFile(sha256: sha256)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            touch(url)
            return url
        }
    }

    /// Keeps `data` as the image `sha256` when its length is `bytes` (when
    /// given) and its SHA-256 is `sha256`; then drops the least recently used
    /// images past ``assetLimit``. Answers the stored file, nil when the data
    /// does not match.
    @discardableResult
    public func storeAsset(_ data: Data, sha256: String, bytes: Int? = nil) -> URL? {
        guard Self.isHash(sha256), bytes == nil || bytes == data.count, Self.sha256(data) == sha256 else { return nil }
        return lock.withLock {
            try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let url = assetFile(sha256: sha256)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            touch(url)
            prune(keeping: url)
            return url
        }
    }

    /// The stored images, most recently used first.
    public func assetHashes() -> [String] {
        lock.withLock { ranked().map { $0.deletingPathExtension().lastPathComponent } }
    }

    private func ranked() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "jpg" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return da != db ? da > db : a.lastPathComponent < b.lastPathComponent
        }
    }

    private func prune(keeping kept: URL) {
        let files = ranked().filter { $0 != kept }
        for stale in files.dropFirst(Self.assetLimit - 1) { try? FileManager.default.removeItem(at: stale) }
    }

    /// Use order is the file's modification date (bumped on each use).
    /// Each stamp is later than the one before, so two uses in one clock tick still rank.
    private func touch(_ url: URL) {
        let stamp = max(Date(), lastStamp.addingTimeInterval(0.001))
        lastStamp = stamp
        try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
    }

    static func isHash(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
