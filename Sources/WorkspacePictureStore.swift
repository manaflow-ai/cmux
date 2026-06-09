import AppKit
import CryptoKit
import Foundation
import OSLog

private let workspacePictureLog = Logger(subsystem: "com.cmuxterm.app", category: "workspace-picture")

/// On-disk store for per-workspace pictures (iMessage-style avatars).
///
/// The image bytes are deliberately kept out of the session JSON snapshot, which
/// is a small state-tree file: a per-workspace picture lives as its own PNG under
/// `<appSupport>/cmux/workspace-pictures-<bundleId>/<workspaceId>.png`, mirroring
/// the bundle-id scoping of `SessionPersistence`. The session snapshot carries
/// only the small `pictureHash` string, so restore re-derives the avatar from the
/// file the same way the live store does.
///
/// Pictures are downscaled to a fixed avatar size and re-encoded as PNG before
/// storage so a multi-megabyte source image never lands on disk or rides the
/// mobile RPC. The content hash is the SHA-256 of the stored PNG bytes, so the
/// phone caches by hash and never refetches an unchanged avatar.
@MainActor
final class WorkspacePictureStore {
    static let shared = WorkspacePictureStore()

    /// Square avatar edge, in pixels, that every stored picture is downscaled to.
    /// 256px is sharp on a Retina sidebar row and on the phone's 48pt avatar while
    /// keeping the PNG well under the mobile payload cap.
    static let avatarPixelSize = 256

    /// Hard cap on a stored (already-downscaled) PNG. A normal 256px avatar is a
    /// few tens of KB; this backstops a pathological encode and bounds the
    /// base64 the phone ever fetches.
    static let maxStoredPictureBytes = 512 * 1024

    private let fileManager: FileManager
    private let bundleIdentifier: String?
    private let appSupportDirectory: URL?

    /// In-memory cache of the current hash per workspace so reads don't hit disk
    /// on every mobile-list build. `nil` means "no picture"; absence means
    /// "not yet probed".
    private var hashCache: [UUID: String?] = [:]
    /// In-memory cache of stored PNG bytes keyed by content hash, so repeated
    /// fetch-by-hash RPCs from the phone don't re-read the file each time.
    private var bytesByHash: [String: Data] = [:]

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundleIdentifier = bundleIdentifier
        self.appSupportDirectory = appSupportDirectory
    }

    // MARK: - Directory resolution

    private func picturesDirectoryURL() -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let safeBundleId = Self.safeBundleIdentifier(bundleIdentifier)
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("workspace-pictures-\(safeBundleId)", isDirectory: true)
    }

    private func pictureFileURL(for workspaceID: UUID) -> URL? {
        picturesDirectoryURL()?.appendingPathComponent("\(workspaceID.uuidString).png", isDirectory: false)
    }

    static func safeBundleIdentifier(_ bundleIdentifier: String?) -> String {
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        return bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
    }

    // MARK: - Reads

    /// Content hash of the workspace's current picture, or `nil` if it has none.
    /// Cheap on the hot mobile-list path: cached in memory, re-derived from disk
    /// only on a cache miss.
    func pictureHash(for workspaceID: UUID) -> String? {
        if let cached = hashCache[workspaceID] {
            return cached
        }
        let data = readStoredPNG(for: workspaceID)
        let hash = data.map { Self.contentHash(of: $0) }
        hashCache[workspaceID] = hash
        if let data, let hash {
            bytesByHash[hash] = data
        }
        return hash
    }

    /// Stored PNG bytes for a workspace whose current picture matches `hash`, or
    /// `nil` if there is no picture or the hash no longer matches (the phone is
    /// asking for a stale avatar). Hash-gated so a fetch can never serve bytes the
    /// caller didn't ask for.
    func pictureData(for workspaceID: UUID, matchingHash hash: String) -> Data? {
        guard let currentHash = pictureHash(for: workspaceID), currentHash == hash else {
            return nil
        }
        if let cached = bytesByHash[hash] {
            return cached
        }
        guard let data = readStoredPNG(for: workspaceID) else { return nil }
        bytesByHash[hash] = data
        return data
    }

    private func readStoredPNG(for workspaceID: UUID) -> Data? {
        guard let url = pictureFileURL(for: workspaceID),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= Self.maxStoredPictureBytes else {
            return nil
        }
        return data
    }

    // MARK: - Writes

    /// Downscale, re-encode, and persist `image` as this workspace's picture,
    /// returning the new content hash. Returns `nil` if the image can't be
    /// encoded (e.g. an empty or corrupt source).
    @discardableResult
    func setPicture(_ image: NSImage, for workspaceID: UUID) -> String? {
        guard let png = Self.normalizedAvatarPNG(from: image) else {
            workspacePictureLog.error("failed to encode workspace picture")
            return nil
        }
        return setPictureData(png, for: workspaceID)
    }

    /// Persist already-encoded avatar PNG bytes (used by the image-pick path and
    /// directly by tests). The bytes are assumed normalized by
    /// `normalizedAvatarPNG`; oversized blobs are rejected.
    @discardableResult
    func setPictureData(_ png: Data, for workspaceID: UUID) -> String? {
        guard !png.isEmpty, png.count <= Self.maxStoredPictureBytes else { return nil }
        guard let directory = picturesDirectoryURL(),
              let url = pictureFileURL(for: workspaceID) else {
            return nil
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            workspacePictureLog.error("failed to persist workspace picture: \(String(describing: error), privacy: .public)")
            return nil
        }
        let hash = Self.contentHash(of: png)
        evictCachedBytesForPreviousHash(of: workspaceID, keeping: hash)
        hashCache[workspaceID] = hash
        bytesByHash[hash] = png
        return hash
    }

    /// Drop the bytes cached under a workspace's previous hash so repeated
    /// picture changes don't accumulate stale PNGs in the in-memory cache. If
    /// another workspace happens to share the evicted hash, its next read is a
    /// cheap cache miss re-served from its own file.
    private func evictCachedBytesForPreviousHash(of workspaceID: UUID, keeping newHash: String? = nil) {
        if case let .some(previousHash) = hashCache[workspaceID],
           let previousHash,
           previousHash != newHash {
            bytesByHash.removeValue(forKey: previousHash)
        }
    }

    /// Remove a workspace's picture from disk and caches.
    func removePicture(for workspaceID: UUID) {
        if let url = pictureFileURL(for: workspaceID) {
            try? fileManager.removeItem(at: url)
        }
        if case let .some(previousHash) = hashCache[workspaceID], let previousHash {
            bytesByHash.removeValue(forKey: previousHash)
        }
        hashCache[workspaceID] = .some(nil)
    }

    /// Drop the in-memory hash entry so the next read re-probes disk (used when a
    /// workspace is closed or restored).
    func invalidateCache(for workspaceID: UUID) {
        hashCache.removeValue(forKey: workspaceID)
    }

    /// On session restore a workspace is rebuilt under a fresh UUID, so its
    /// picture file (named by the original id) must be re-homed onto the new id.
    /// Moves `<sourceID>.png` to `<destinationID>.png` and returns the resulting
    /// content hash, or `nil` if the source has no stored picture. No-op when the
    /// ids match.
    @discardableResult
    func migratePicture(from sourceID: UUID, to destinationID: UUID) -> String? {
        guard sourceID != destinationID else {
            return pictureHash(for: destinationID)
        }
        guard let sourceURL = pictureFileURL(for: sourceID),
              let destinationURL = pictureFileURL(for: destinationID),
              fileManager.fileExists(atPath: sourceURL.path) else {
            return nil
        }
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            workspacePictureLog.error("failed to migrate workspace picture: \(String(describing: error), privacy: .public)")
            return nil
        }
        // The destination's previous picture (if any) was just overwritten on
        // disk; drop its now-stale cached bytes before re-probing.
        evictCachedBytesForPreviousHash(of: destinationID)
        invalidateCache(for: sourceID)
        invalidateCache(for: destinationID)
        return pictureHash(for: destinationID)
    }

    // MARK: - Encoding helpers (pure, testable)

    /// SHA-256 of the bytes, hex-encoded and truncated to 16 chars. A 64-bit
    /// prefix is collision-safe for a per-user avatar set and keeps the mobile
    /// payload field tiny.
    static func contentHash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Downscale `image` to a centered square `avatarPixelSize` PNG. Returns `nil`
    /// for an empty/unrenderable image. Pure: no disk or instance state, so the
    /// store's encoding contract is unit-testable.
    static func normalizedAvatarPNG(
        from image: NSImage,
        pixelSize: Int = avatarPixelSize
    ) -> Data? {
        guard pixelSize > 0, image.size.width > 0, image.size.height > 0 else { return nil }
        let side = CGFloat(pixelSize)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = NSSize(width: side, height: side)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        // Aspect-fill: scale the source so the shorter edge fills the square, then
        // center it so a non-square source crops to a square avatar instead of
        // distorting.
        let sourceAspect = image.size.width / image.size.height
        let drawRect: NSRect
        if sourceAspect >= 1 {
            let scaledWidth = side * sourceAspect
            drawRect = NSRect(x: (side - scaledWidth) / 2, y: 0, width: scaledWidth, height: side)
        } else {
            let scaledHeight = side / sourceAspect
            drawRect = NSRect(x: 0, y: (side - scaledHeight) / 2, width: side, height: scaledHeight)
        }
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}

/// Pasteboard helpers for the "Paste Picture" context-menu affordance, kept
/// alongside the picture store so all workspace-picture concerns live together.
enum WorkspacePicturePasteboardSupport {
    /// Whether the general pasteboard currently holds an image (drives whether the
    /// "Paste Picture" menu item is shown).
    static var hasImage: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Read an image off the general pasteboard, or `nil` if it holds none.
    static func imageFromPasteboard() -> NSImage? {
        NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
    }
}
