import CmuxNextCompat
import CmuxNextDesign
package import CmuxNextWakeups
package import CoreGraphics
package import Foundation
import ImageIO
import os

/// Browser tabs' last pictures on disk, so a tab first shown after a relaunch shows its last page in the frame of
/// the switch, then its new page under that picture until the page paints, as a woken tab does
/// (`BrowserWakeStandIn`). Leo 2026-11-22: "this is so fucked. constant rerenders on every fucking page still." A
/// Chromium page is made on a tab's first show, so every tab not shown since the relaunch showed the bare pane and
/// then a cold load for seconds; the pictures that could cover it (`pageThumbnails`, hibernation's) lived in
/// memory only.
///
/// A picture is written when the app pictures a page anyway (its leave picture) and at quit for the pages on screen, as terminals keep their frames (`TerminalLaunchFrames`, the same file names:
/// `LaunchFrameFiles`). The folder holds at most ``capacity`` bytes, least recently written out first; a closed tab's
/// file goes with it, and an incognito page's is never written (the cache asks before it saves).
///
/// The launch reads the files' bytes (compressed, the folder's budget at most) off the main thread
/// (``prefetch(on:)``); a tab shown after that gets its picture with no disk read, decoded when first drawn. A tab
/// shown before the read ended gets none, as with no picture. Each picture is handed out once (``take(_:)``): the
/// tab's live page draws from then on, and its next leave picture replaces the file.
package final class BrowserPageFrames {
    /// The folder of the pictures in the app's state directory (beside the terminals' frames).
    package static let directoryName = "browser-page-frames"
    /// The folder's budget (a page picture at 2x is about 0.2 to 1.5 MB as JPEG, as for `HibernationSnapshots`).
    package nonisolated static let capacity = 64 << 20
    /// A larger picture is not written or read.
    nonisolated static let maximumBytes = 8 << 20
    /// JPEG quality of an opaque picture (`LaunchFrameFiles.encoded`).
    nonisolated static let jpegQuality = 0.8
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser.page-frames")

    package let directory: URL?
    package let capacity: Int
    private var work: BackgroundWork?
    /// The last run's pictures, compressed, by tab key; nil until the launch read ended.
    private var saved: [String: Data]?
    /// The pixels per point of each of the last run's pictures (its file name's), by tab key.
    private var savedScales: [String: Int] = [:]
    /// Pictures saved in this run whose file is not written yet: ``lastFrame(_:)`` hands them out before the file,
    /// so a read never finds the picture this one replaces (cmux#57419 review: the read's lane can run first).
    private var pending: [String: (image: CGImage, scale: Int)] = [:]
    /// Set at quit before its own writes: no write or removal posted earlier lands after them.
    private let stopped = StopFlag()
    /// The tabs with a picture in the folder: the last run's the launch read, and each saved in this run (handed out
    /// or not). The phones' tab overview sends each one's picture (``lastPicture(_:)``) for a tab whose page is not
    /// made since the relaunch or was hibernated, so its card is never empty.
    package private(set) var keys: Set<String> = []

    package init(directory: URL?, capacity: Int = capacity) {
        self.directory = directory
        self.capacity = capacity
    }

    /// The pictures kept in `state`, the app's state directory (beside the terminals' frames).
    package convenience init(beside state: URL?) {
        self.init(directory: state?.appending(path: Self.directoryName, directoryHint: .isDirectory))
    }

    /// The pixels per point (1 to 3) of `image` drawn `width` points wide; 2 when the width is unknown.
    package static func scale(of image: CGImage, width: CGFloat) -> Int {
        width > 0 ? min(3, max(1, Int((CGFloat(image.width) / width).rounded()))) : 2
    }

    /// Starts the read of the last run's pictures on `work`'s files lane; a later call does nothing.
    /// - Returns: A task that ends once the read's pictures are here (tests await it).
    @discardableResult
    package func prefetch(on work: BackgroundWork) -> Task<Void, Never> {
        guard self.work == nil else { return Task {} }
        self.work = work
        guard let directory else { saved = [:]; return Task {} }
        let capacity = capacity
        return Task { [weak self] in
            let frames = (try? await work.run(.userVisible, mayBlock: .files) { Self.readFrames(in: directory, capacity: capacity) }) ?? [:]
            guard let self else { return }
            // A picture saved or removed in this run meanwhile is newer than the read's.
            let removed = removedDuringRead, read = frames.mapValues(\.data)
            savedScales = frames.mapValues(\.scale)
            saved = read.merging(saved ?? [:]) { _, current in current }.filter { !$0.value.isEmpty }
            keys.formUnion(read.keys.filter { !removed.contains($0) })
            removedDuringRead = []
        }
    }

    /// Tabs removed before the launch read ended: the read's picture of each is gone.
    private var removedDuringRead: Set<String> = []

    /// Whether `key` has a picture from the last run that was not handed out yet.
    package func hasPicture(_ key: String) -> Bool { saved?[key]?.isEmpty == false }

    /// `key`'s picture from the last run (decoded when first drawn), handed out once; nil when it has none or the
    /// launch read has not ended.
    package func take(_ key: String) -> CGImage? { takeFrame(key)?.image }

    /// ``take(_:)`` with the picture's pixels per point (the page area's backing scale when it was taken).
    package func takeFrame(_ key: String) -> (image: CGImage, scale: Int)? {
        guard let data = saved?[key], !data.isEmpty else { return nil }
        saved?[key] = nil
        return Self.image(data).map { ($0, savedScales[key] ?? 2) }
    }

    /// `key`'s last picture without handing it out: the last run's while it was not handed out, else its file, read
    /// off the main thread; nil when it has none. For the phones' tab overview, which needs a picture of a tab whose
    /// page has none to give (not made since the relaunch, or its pictures in memory went).
    package func lastPicture(_ key: String) async -> CGImage? { await lastFrame(key)?.image }

    /// ``lastPicture(_:)`` with its pixels per point and, when read from its file, its compressed bytes (nil for a
    /// picture of this run whose file is not written yet, handed out as it was saved).
    package func lastFrame(_ key: String) async -> (image: CGImage, data: Data?, scale: Int)? {
        if let picture = pending[key] { return (picture.image, nil, picture.scale) }
        if let data = saved?[key], !data.isEmpty { return Self.image(data).map { ($0, data, savedScales[key] ?? 2) } }
        guard keys.contains(key), let directory, let work, LaunchFrameFiles.isFileSafe(key) else { return nil }
        guard let file = try? await work.run(.bestEffort, mayBlock: .files, { Self.readFrame(key, in: directory) }) else { return nil }
        return Self.image(file.data).map { ($0, file.data, file.scale) }
    }

    private nonisolated static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Writes `image` as `key`'s picture (off the main thread), replacing its last one and keeping the folder in its
    /// budget. A picture of this run replaces the last run's in memory too: it is no longer handed out.
    package func save(_ image: CGImage, for key: String, scale: Int = 2) {
        guard let directory, let work, LaunchFrameFiles.isFileSafe(key), !stopped.isSet else { return }
        saved?[key] = Data()
        keys.insert(key)
        pending[key] = (image, scale)
        let capacity = capacity, stopped = stopped
        work.post(.bestEffort, mayBlock: .files) { [weak self] in
            defer { MainDelivery().run { if self?.pending[key]?.image === image { self?.pending[key] = nil } } }
            guard !stopped.isSet else { return }
            // A picture that cannot be written takes the older one with it: no read finds a picture this one replaced.
            guard let data = Self.encoded(image) else { return Self.removeAll(of: key, in: directory) }
            Self.write(data, key: key, scale: scale, to: directory, capacity: capacity)
        }
    }

    /// `key`'s tab closed: its picture goes (none after a quit began: its tabs close, and reopen at the next launch).
    package func remove(_ key: String) {
        guard let directory, let work, !stopped.isSet else { return }
        saved?[key] = nil
        keys.remove(key)
        pending[key] = nil
        if saved == nil { removedDuringRead.insert(key) }
        let stopped = stopped
        work.post(.bestEffort, mayBlock: .files) {
            guard !stopped.isSet else { return }
            Self.removeAll(of: key, in: directory)
        }
    }

    /// The quit: every write and removal posted before stops here; `images` (the pages on screen) are written and
    /// awaited.
    package func saveForQuit(_ images: [String: (image: CGImage, scale: Int)]) async {
        stopped.set()
        guard let directory, let work else { return }
        let capacity = capacity
        for (key, picture) in images where LaunchFrameFiles.isFileSafe(key) {
            let image = picture.image, scale = picture.scale
            _ = try? await work.run(.userBlocking, mayBlock: .files) {
                guard let data = Self.encoded(image) else { return }
                Self.write(data, key: key, scale: scale, to: directory, capacity: capacity)
            }
        }
        logger.notice("quit: \(images.count) page pictures written")
    }

    // MARK: Files

    package nonisolated static func encoded(_ image: CGImage) -> Data? {
        LaunchFrameFiles.encoded(image, jpegQuality: jpegQuality, maximumBytes: maximumBytes)
    }

    /// Every saved picture's bytes in `directory`, newest first, until `capacity` bytes.
    package nonisolated static func readAll(in directory: URL, capacity: Int) -> [String: Data] {
        readFrames(in: directory, capacity: capacity).mapValues(\.data)
    }

    /// ``readAll(in:capacity:)`` with each picture's pixels per point (its file name's).
    package nonisolated static func readFrames(in directory: URL, capacity: Int) -> [String: (data: Data, scale: Int)] {
        var pictures: [String: (data: Data, scale: Int)] = [:]
        var total = 0
        for file in files(in: directory) where pictures[file.key] == nil {
            guard total + file.size <= capacity, file.size <= maximumBytes,
                  let data = try? Data(blockingContentsOf: directory.appending(path: file.name)) else { continue }
            pictures[file.key] = (data, LaunchFrameFiles.scale(of: file.name) ?? 2)
            total += data.count
        }
        return pictures
    }

    /// The bytes of `key`'s newest picture file in `directory`; nil when it has none or it is too large.
    package nonisolated static func read(_ key: String, in directory: URL) -> Data? { readFrame(key, in: directory)?.data }

    /// ``read(_:in:)`` with the picture's pixels per point (its file name's).
    package nonisolated static func readFrame(_ key: String, in directory: URL) -> (data: Data, scale: Int)? {
        guard let file = files(in: directory).first(where: { $0.key == key }), file.size <= maximumBytes,
              let data = try? Data(blockingContentsOf: directory.appending(path: file.name)) else { return nil }
        return (data, LaunchFrameFiles.scale(of: file.name) ?? 2)
    }

    /// Writes `key`'s picture, removes its others, then the least recently written pictures past `capacity`.
    package nonisolated static func write(_ data: Data, key: String, scale: Int, to directory: URL, capacity: Int) {
        let manager = FileManager.checked
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = LaunchFrameFiles.name(key, scale: scale), url = directory.appending(path: name)
        guard (try? data.blockingWrite(to: url, options: [.atomic])) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var total = 0
        for file in files(in: directory) {
            if file.name == name { total += file.size; continue }
            if file.key == key || total + file.size > capacity {
                try? manager.removeItem(at: directory.appending(path: file.name))
            } else {
                total += file.size
            }
        }
    }

    package nonisolated static func removeAll(of key: String, in directory: URL) {
        let manager = FileManager.checked
        for file in files(in: directory) where file.key == key {
            try? manager.removeItem(at: directory.appending(path: file.name))
        }
    }

    /// The saved pictures in `directory`, newest first.
    package nonisolated static func files(in directory: URL) -> [(name: String, key: String, size: Int)] {
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (name: String, key: String, size: Int, date: Date)? in
            guard let key = LaunchFrameFiles.owner(of: name), LaunchFrameFiles.isFileSafe(key),
                  let values = try? directory.appending(path: name).blockingResourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return nil }
            return (name, key, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.name < $1.name }
        .map { ($0.name, $0.key, $0.size) }
    }
}

/// Set once, read from any thread: shared by the store and the writes it posts (a `Mutex` cannot be captured).
private nonisolated final class StopFlag: Sendable {
    // carve-out justification: a set-once flag read by writes on BackgroundWork threads; no actor can be read synchronously there.
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
