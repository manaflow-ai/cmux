import CmuxNextBridge
import CmuxNextCompat
package import CmuxNextSettings
package import CoreGraphics
package import Foundation
import ImageIO

/// Hibernated pages' last frames, kept compressed (JPEG, or PNG when transparent) in files of the
/// store's own directory, under a disk budget, least recently used first out, so every hibernated
/// tab wakes to its picture. A hibernated page costs the app's memory a path and a byte count: 500
/// pictures held in RAM filled a 64 MB budget and 137 of them were dropped.
///
/// A new picture is held in memory until its file is written (a background write; `memoryBytes`),
/// so it answers at once. A file-backed picture's image is made from its file when asked for (ImageIO
/// reads the header; the pixels decode where the image is drawn), and stays drawable after the store
/// deletes the file (a woken page's stand-in decodes it after the store let it go). The placeholder
/// asks for it only when a pane shows it, decodes it off the main thread, and holds the decoded
/// pixels only while shown (`HibernatedBrowserTab`). Files are written and deleted off the main thread.
@MainActor
package final class HibernationSnapshots {
    /// A page picture at 2x is about 0.2 to 1.5 MB as JPEG, so the default 512 MB holds 350 to
    /// 2,800 of them. Bounds bytes on disk plus bytes still being written.
    package let capacityBytes: Int
    /// Bytes of every kept picture, on disk or still being written (`debug.surfaces` `snapshot_bytes`).
    package private(set) var totalBytes = 0
    /// Bytes of pictures still held in memory while their file is written (`snapshot_memory_bytes`).
    package private(set) var memoryBytes = 0
    /// Pictures dropped to stay within `capacityBytes`, or whose file could not be written (`debug.surfaces`
    /// `snapshot_evicted`): a hibernated page that had a picture and lost it, told apart from one that never had one.
    package private(set) var evicted = 0
    /// Hibernating pages that kept no picture, by why (`debug.surfaces` `snapshot_missing`; `noteMissing`).
    package private(set) var missing: [String: Int] = [:]
    /// Where the pictures' files live.
    package let directory: URL
    /// The directory the store made for itself, removed with it; nil when the caller gave one.
    private let ownDirectory: URL?
    private var entries: [String: Entry] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var nextToken: UInt64 = 0
    /// File writes and deletions not yet done (`settled()`).
    private var pending: [UInt64: Task<Void, Never>] = [:]

    /// One page's picture: `data` is the JPEG or PNG, `image` decodes from it. `scale`: its pixels per point (the
    /// page area it pictures is `image.width / scale` points wide), so it is drawn at its own size (cmux#57419); nil
    /// when unknown (drawn at the window's backing scale).
    package nonisolated struct Picture: Sendable {
        package let data: Data
        package let image: CGImage
        package var scale: CGFloat?

        package init(data: Data, image: CGImage, scale: CGFloat? = nil) {
            self.data = data
            self.image = image
            self.scale = scale
        }
    }

    private struct Entry {
        /// Which insert made it: a write that finishes after its key was replaced or removed finds another token.
        let token: UInt64
        let bytes: Int
        var stored: Stored
        var scale: CGFloat?
    }

    private enum Stored {
        case memory(Picture)
        case file(URL)
    }

    /// A store's own directory is named this, then its process id, then a UUID.
    private nonisolated static let directoryPrefix = "cmux-hibernation-snapshots-"

    /// `directory` nil: a new directory of its own in the temporary directory, removed when the store goes.
    /// Keys name tabs of this launch only, so no file is read again after a relaunch; the directory of a
    /// launch that quit or crashed is removed by the next launch's first write (`removeDeadStores`).
    package init(capacityBytes: Int = 512 << 20, directory: URL? = nil) {
        self.capacityBytes = capacityBytes
        if let directory {
            self.directory = directory
            ownDirectory = nil
        } else {
            let made = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(Self.directoryPrefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
            self.directory = made
            ownDirectory = made
        }
    }

    nonisolated deinit {
        guard let ownDirectory else { return }
        // task-owner: the store is gone; its directory is removed off the main thread, once
        Task.detached(priority: .utility) { HibernationSnapshots.deleteFile(ownDirectory) }
    }

    package var count: Int { entries.count }

    /// The file holding `key`'s picture; nil while it is written, or when there is none.
    package func fileURL(for key: String) -> URL? {
        guard case .file(let url)? = entries[key]?.stored else { return nil }
        return url
    }

    /// The pixels per point of `key`'s picture (``Picture/scale``); nil when it has none or it is unknown.
    package func scale(for key: String) -> CGFloat? { entries[key]?.scale }

    package func image(for key: String) -> CGImage? {
        guard let entry = entries[key] else { return nil }
        let image: CGImage
        switch entry.stored {
        case .memory(let picture):
            image = picture.image
        case .file(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let made = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                remove(key)
                return nil
            }
            image = made
        }
        order.removeAll { $0 == key }
        order.append(key)
        return image
    }

    package func insert(_ picture: Picture, for key: String) {
        let cost = picture.data.count
        guard cost <= capacityBytes else { return }
        remove(key)
        nextToken += 1
        let token = nextToken
        entries[key] = Entry(token: token, bytes: cost, stored: .memory(picture), scale: picture.scale)
        order.append(key)
        totalBytes += cost
        memoryBytes += cost
        while totalBytes > capacityBytes, let oldest = order.first { remove(oldest); evicted += 1 }
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        let data = picture.data, directory = directory
        pending[token] = Task { [weak self] in
            let written = await Task.detached(priority: .utility) { HibernationSnapshots.writeFile(data, to: url, in: directory) }.value
            guard let self else { return } // the store's directory goes with it
            self.pending[token] = nil
            self.finishWrite(key, token: token, url: url, written: written)
        }
    }

    package func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.bytes
        order.removeAll { $0 == key }
        switch entry.stored {
        case .memory: memoryBytes -= entry.bytes // its write, when it lands, deletes its file
        case .file(let url): delete(url)
        }
    }

    /// A hibernating Chromium page kept no picture: its leave picture, of URL `pictured` (nil: it has none), was of an
    /// earlier URL than `current`, or of this one with no full-size frame on disk (incognito, or the frames' budget
    /// dropped it).
    package func noteMissing(pictured: String?, current: String?) {
        missing[pictured == nil ? "no_leave_picture" : pictured == current ? "leave_frame_missing" : "url_moved", default: 0] += 1
    }

    /// The store's `debug.surfaces` fields.
    package var json: [String: JSONValue] {
        ["snapshots": JSONValue(count), "snapshot_bytes": JSONValue(totalBytes), "snapshot_memory_bytes": JSONValue(memoryBytes),
         "snapshot_evicted": JSONValue(evicted), "snapshot_missing": .object(missing.mapValues { JSONValue($0) })]
    }

    /// Returns once every file write and deletion started so far is done (tests).
    package func settled() async {
        while let task = pending.values.first { await task.value }
    }

    /// A picture's file is written: the entry, if it is still this insert's, now reads from the file and
    /// its bytes leave memory. A file nobody wants is deleted; a write that failed drops the picture, so
    /// memory does not grow when the disk is full.
    private func finishWrite(_ key: String, token: UInt64, url: URL, written: Bool) {
        guard let entry = entries[key], entry.token == token, case .memory = entry.stored else {
            if written { delete(url) }
            return
        }
        guard written else {
            remove(key)
            evicted += 1
            return
        }
        entries[key]?.stored = .file(url)
        memoryBytes -= entry.bytes
    }

    private func delete(_ url: URL) {
        nextToken += 1
        let token = nextToken
        pending[token] = Task { [weak self] in
            await Task.detached(priority: .utility) { HibernationSnapshots.deleteFile(url) }.value
            self?.pending[token] = nil
        }
    }

    /// `image` as a JPEG at most `PreviewImageCache.maxCompressedPixels` large (same aspect and color space), encoded on a
    /// background task; a PNG when it has transparent pixels, which JPEG would turn black (a page
    /// with a transparent background); nil when ImageIO cannot encode it.
    package nonisolated static func compress(_ image: CGImage, quality: Double = 0.8) async -> Picture? {
        await Task.detached(priority: .userInitiated) { compressed(image, quality: quality) }.value
    }

    /// The picture of a page area `points` wide: `image` compressed (``compress(_:quality:)``, which may scale it
    /// down), or kept as the compressed `data` it decodes from, with its pixels per point (`scale`, else its pixels
    /// over `points`; unknown when `points` is not positive), so it is drawn at the page area's size, sharp when it
    /// has the pixels for it and never stretched past that size (cmux#57419).
    package nonisolated static func picture(of image: CGImage, data: Data? = nil, scale: CGFloat? = nil, pointsWide points: CGFloat) async -> Picture? {
        let made: Picture? = if let data { Picture(data: data, image: image) } else { await compress(image) }
        guard var picture = made else { return nil }
        if let scale { picture.scale = scale * CGFloat(picture.image.width) / CGFloat(max(image.width, 1)) }
        else if points > 0 { picture.scale = CGFloat(picture.image.width) / points }
        return picture
    }

    package nonisolated static func compressed(_ image: CGImage, quality: Double) -> Picture? {
        PreviewImageCache.compressed(image, quality: quality).map { Picture(data: $0.data, image: $0.image) }
    }

    /// Writes a picture's file in `directory`, made first when missing (off the main thread).
    private nonisolated static func writeFile(_ data: Data, to url: URL, in directory: URL) -> Bool {
        if (try? data.blockingWrite(to: url)) != nil { return true }
        try? FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
        removeDeadStores(beside: directory)
        return (try? data.blockingWrite(to: url)) != nil
    }

    /// Removes the directories of stores whose process is gone (an app that quit or crashed never ran
    /// `deinit`), so pictures on disk do not pile up launch over launch. Once per store, with its first write.
    private nonisolated static func removeDeadStores(beside directory: URL) {
        let parent = directory.deletingLastPathComponent()
        for name in (try? FileManager.checked.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(directoryPrefix) {
            guard let pid = pid_t(name.dropFirst(directoryPrefix.count).prefix { $0.isNumber }), pid > 0, pid != getpid(),
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            deleteFile(parent.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Deletes a picture's file, or the store's directory (off the main thread).
    private nonisolated static func deleteFile(_ url: URL) {
        try? FileManager.checked.removeItem(at: url)
    }
}
