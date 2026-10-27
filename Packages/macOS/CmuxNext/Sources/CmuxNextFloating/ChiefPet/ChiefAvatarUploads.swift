public import AppKit
public import Foundation
import CmuxNextCompat
import CmuxNextWakeups
import ImageIO
import Observation
public import UniformTypeIdentifiers

/// The person's own avatars, one per Chief (and, by key, per agent session), kept on this Mac only
/// (Leo 2026-10-26: "have guys make their own and then, like, upload their own if they have things
/// from elsewhere for the avatars"). An upload is the Chief's pet character while it is worn: the
/// floating pet plays it (a GIF moves there only), and every other avatar surface draws its first
/// frame. Picking a built-in character keeps the upload in the grid, unworn; Remove deletes it, and
/// the character picked before shows again.
///
/// Files live under `Application Support/<bundle id>/AvatarUploads/<key>/`: `<stamp>-still.png`
/// (the first frame, drawn down to ``stillSide``) and, for a moving GIF, `<stamp>.gif` as given. A
/// new stamp per upload gives each one its own URL, so a cache keyed by path never shows the old one.
/// Nothing here leaves the machine.
///
/// ```swift
/// let uploads = ChiefAvatarUploads(folder: ChiefAvatarUploads.defaultFolder)
/// try await uploads.store(from: pickedFile, for: ChiefAvatarUploads.key(chief: "agent_mux"), over: mascot)
/// uploads.worn(of: ChiefAvatarUploads.key(chief: "agent_mux"), over: mascot)?.still  // what the sidebar draws
/// ```
@Observable @MainActor
public final class ChiefAvatarUploads {
    /// One stored upload.
    public nonisolated struct Upload: Equatable, Sendable {
        /// What the pet draws: the GIF when it moves, else the still.
        public var file: URL
        /// The first frame as a PNG, for every surface that never animates.
        public var still: URL
        /// The character picked when it was worn; nil when it is kept but not worn. It is worn only
        /// while that character is still the pick, so a pick anywhere (this grid, Settings) replaces it.
        public var wornOver: String?
    }

    /// Why an upload was refused; ``message`` says it in the person's words.
    public nonisolated enum Refusal: Error, Equatable, Sendable {
        case unreadable, tooLarge, tooManyPixels, gifTooLarge, gifTooBig, unsaved

        @MainActor public var message: String {
            switch self {
            case .unreadable, .tooLarge, .tooManyPixels, .gifTooLarge, .gifTooBig: ChiefPetStrings.uploadLimits
            case .unsaved: ChiefPetStrings.uploadUnsaved
            }
        }
    }

    /// What the file picker and a drop take.
    public nonisolated static let types: [UTType] = [.png, .jpeg, .webP, .heic, .gif]
    /// The largest file taken at all (a still is drawn down, so only reading it costs).
    public nonisolated static let maximumBytes = 20 * 1024 * 1024
    /// The largest still taken, in pixels per side, read from its header before it is decoded.
    public nonisolated static let maximumPixels = 8192
    /// A still is kept drawn down to this many pixels per side.
    public nonisolated static let stillSide = 512
    /// A moving GIF is kept as it is, so it must already be small (FORMAT.md `cmux-avatar/1`).
    public nonisolated static let maximumGIFBytes = 512 * 1024
    public nonisolated static let maximumGIFPixels = 256
    /// The file beside a worn upload naming the character picked when it was worn (``Upload/wornOver``).
    nonisolated static let wornMarker = "worn"

    @ObservationIgnored private let folder: URL?
    /// Each key's upload.
    public private(set) var uploads: [String: Upload]
    /// Each upload's first frame, decoded off the main actor before the upload is published.
    @ObservationIgnored private var images: [URL: CGImage] = [:]

    // MARK: The one serial owner
    //
    // Every operation goes through one line of steps (``serially(_:)``), in the order it was asked
    // for: the launch listing first, then each upload, removal and pick's file work and what it
    // publishes. Each asks for a generation when it is called (``tick()``), so what lands later
    // never undoes an intent asked for after it: a removal or a pick made during the listing or
    // during an upload wins, and a refused upload changes nothing.

    /// The last step of the line; the next starts after it.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// The generations handed out so far, one per upload, removal and pick.
    @ObservationIgnored private var clock = 0
    /// Each key's newest removal and newest pick, by generation.
    @ObservationIgnored private var removedAt: [String: Int] = [:]
    @ObservationIgnored private var woreAt: [String: (generation: Int, mascot: String?)] = [:]
    /// Whether the launch listing is published; until it is, picks and removals wait for it in
    /// order (``now(_:)``), and then apply over what the folder held.
    @ObservationIgnored private var listed = false
    @ObservationIgnored private var waiting: [@MainActor () -> Void] = []
    /// The launch listing (the line's first step); nil with no folder.
    @ObservationIgnored private var listing: Task<Void, Never>?

    /// - Parameter folder: where uploads are kept; nil keeps nothing (a test, or no support folder).
    public init(folder: URL?) {
        self.folder = folder
        uploads = [:]
        guard let folder else {
            listed = true
            return
        }
        // The line's first step: the folder as the last run left it (first frames decoded off the main actor).
        listing = serially { [weak self] in
            let found = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { Self.scan(folder) }.value
            guard let self else { return }
            for (key, entry) in found {
                images[entry.upload.still] = entry.image
                uploads[key] = entry.upload
            }
            listed = true
            let changes = waiting
            waiting = []
            for change in changes { change() }
        }
    }

    /// Runs `step` after every step asked for before it, on the main actor (its file work goes off it).
    private func serially<T: Sendable>(_ step: @escaping @MainActor @Sendable () async -> T) -> Task<T, Never> {
        let previous = tail
        // task-owner: one step of the uploads' serial line; ends with it
        let task = Task { @MainActor in
            await previous?.value
            return await step()
        }
        // task-owner: the line's tail; ends with `task`
        tail = Task { _ = await task.value }
        return task
    }

    private func tick() -> Int {
        clock += 1
        return clock
    }

    /// Applies `change` to what is published now, or, before the listing is, right after it.
    private func now(_ change: @escaping @MainActor () -> Void) {
        if listed { change() } else { waiting.append(change) }
    }

    /// Returns once the launch listing is published (at once when it is): a reader that must not
    /// take "no upload yet" for "no upload" (an agent page asking right at launch) waits for it.
    public func ready() async {
        await listing?.value
    }

    /// Returns when every step asked for so far has run (tests).
    func settled() async {
        await tail?.value
    }

    /// `Application Support/<bundle id>/AvatarUploads`.
    public nonisolated static var defaultFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
            .appendingPathComponent("AvatarUploads", isDirectory: true)
    }

    /// The key of Chief `chief` (a participant id).
    public nonisolated static func key(chief: String) -> String { "chief-" + safe(chief) }
    /// The key of agent session `session`.
    public nonisolated static func key(agent session: String) -> String { "agent-" + safe(session) }

    private nonisolated static func safe(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "_"
    }

    /// Whether `key` is one ``key(chief:)`` or ``key(agent:)`` makes: one folder name of letters,
    /// digits and percent escapes after its prefix, so it never names a path outside the uploads folder.
    public nonisolated static func isKey(_ key: String) -> Bool {
        let prefixes = ["chief-", "agent-"]
        guard let prefix = prefixes.first(where: key.hasPrefix), key.count > prefix.count else { return false }
        return key.dropFirst(prefix.count).unicodeScalars.allSatisfy { $0 == "%" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// `key`'s upload while it is worn over `mascot` (the character picked now); nil when there is
    /// none, it is kept unworn, or another character was picked since it was worn.
    public func worn(of key: String, over mascot: String) -> Upload? {
        uploads[key].flatMap { $0.wornOver == mascot ? $0 : nil }
    }

    /// The first frame of the upload whose still is `still`, already decoded; nil for any other file.
    public func image(at still: URL) -> CGImage? { images[still] }

    /// Makes `source` `key`'s upload and wears it over `mascot` (the character picked now), after
    /// checking it against the limits. Reading, drawing down and writing run off the main actor, in
    /// the serial line; a removal or a pick asked for meanwhile wins.
    public func store(from source: URL, for key: String, over mascot: String) async throws(Refusal) {
        try await storing(from: source, for: key, over: mascot).value.get()
    }

    /// ``store(from:for:over:)``'s step, asked for now (its generation and its place in the line).
    func storing(from source: URL, for key: String, over mascot: String) -> Task<Result<Void, Refusal>, Never> {
        guard let folder, Self.isKey(key) else { return Task { .failure(.unsaved) } }
        let generation = tick()
        return serially { [weak self] in
            let result = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { () -> Result<(upload: Upload, image: CGImage), Refusal> in
                do throws(Refusal) {
                    let prepared = try Self.prepare(source)
                    // Decoded before it is kept: a still that cannot be drawn is never published.
                    guard let image = Self.decode(prepared.still) else { throw .unreadable }
                    let upload = try Self.write(prepared, over: mascot, in: folder.appendingPathComponent(key, isDirectory: true))
                    return .success((upload, image))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return .success(()) }
            switch result {
            case .failure(let refusal):
                return .failure(refusal)
            case .success(var stored):
                // A removal asked for after this upload deletes it next in the line: it is not shown.
                guard removedAt[key, default: 0] < generation else { return .success(()) }
                // A pick asked for after it: its marker is written next in the line, and it shows now.
                if let pick = woreAt[key], pick.generation > generation { stored.upload.wornOver = pick.mascot }
                images[stored.upload.still] = stored.image
                uploads[key] = stored.upload
                return .success(())
            }
        }
    }

    /// Wears `key`'s upload over `mascot` (the character picked now), or, nil, keeps it unworn.
    public func wear(_ key: String, over mascot: String?) {
        guard Self.isKey(key) else { return }
        woreAt[key] = (tick(), mascot)
        if let folder {
            let directory = folder.appendingPathComponent(key, isDirectory: true)
            let marker = directory.appendingPathComponent(Self.wornMarker)
            _ = serially {
                // Only in real folders (never through a link), and only beside an upload.
                await Task.detached(priority: WorkPriority.userBlocking.taskPriority) {
                    guard Self.isPlainFolder(folder), Self.isPlainFolder(directory) else { return }
                    if let mascot { try? Data(mascot.utf8).blockingWrite(to: marker, options: .atomic) } else {
                        try? FileManager.checked.removeItem(at: marker)
                    }
                }.value
            }
        }
        now { [weak self] in
            guard let self, var upload = uploads[key], upload.wornOver != mascot else { return }
            upload.wornOver = mascot
            uploads[key] = upload
        }
    }

    /// Deletes `key`'s upload: the character picked before it shows again.
    public func remove(_ key: String) {
        guard Self.isKey(key) else { return }
        removedAt[key] = tick()
        if let folder {
            let directory = folder.appendingPathComponent(key, isDirectory: true)
            _ = serially {
                // Never through a linked uploads folder; a linked key folder loses only its link.
                await Task.detached(priority: WorkPriority.bestEffort.taskPriority) {
                    if Self.isPlainFolder(folder) { try? FileManager.checked.removeItem(at: directory) }
                }.value
            }
        }
        now { [weak self] in
            guard let self, let upload = uploads.removeValue(forKey: key) else { return }
            images[upload.still] = nil
        }
    }

    // MARK: Files

    /// The still's PNG and, for a GIF with more than one frame, the GIF's bytes as given.
    nonisolated static func prepare(_ source: URL) throws(Refusal) -> (still: Data, gif: Data?) {
        let bytes = (try? source.blockingResourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard bytes > 0 else { throw .unreadable }
        guard bytes <= maximumBytes else { throw .tooLarge }
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 0,
              let type = (CGImageSourceGetType(image) as String?).flatMap(UTType.init),
              types.contains(where: { type.conforms(to: $0) }),
              let header = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = header[kCGImagePropertyPixelWidth] as? Int, let height = header[kCGImagePropertyPixelHeight] as? Int
        else { throw .unreadable }
        guard max(width, height) <= maximumPixels else { throw .tooManyPixels }
        var gif: Data?
        if type.conforms(to: .gif), CGImageSourceGetCount(image) > 1 {
            guard bytes <= maximumGIFBytes else { throw .gifTooLarge }
            guard max(width, height) <= maximumGIFPixels, gifFitsLimits(image) else { throw .gifTooBig }
            gif = try? Data(blockingContentsOf: source)
            guard gif != nil else { throw .unreadable }
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(stillSide, max(width, height))]
        let still = NSMutableData()
        guard let frame = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
              let png = CGImageDestinationCreateWithData(still as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw .unreadable }
        CGImageDestinationAddImage(png, frame, nil)
        guard CGImageDestinationFinalize(png) else { throw .unreadable }
        return (still as Data, gif)
    }

    /// Whether the GIF's canvas and every frame (read from their headers, none decoded) fit
    /// ``maximumGIFPixels``.
    nonisolated static func gifFitsLimits(_ image: CGImageSource) -> Bool {
        let whole = CGImageSourceCopyProperties(image, nil) as? [CFString: Any]
        let canvas = whole?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let side = [kCGImagePropertyGIFCanvasPixelWidth, kCGImagePropertyGIFCanvasPixelHeight].compactMap { canvas?[$0] as? Int }.max() ?? 0
        guard side <= maximumGIFPixels else { return false }
        return (0..<CGImageSourceGetCount(image)).allSatisfy { index in
            guard let frame = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any],
                  let width = frame[kCGImagePropertyPixelWidth] as? Int, let height = frame[kCGImagePropertyPixelHeight] as? Int
            else { return false }
            return max(width, height) <= maximumGIFPixels
        }
    }

    /// The first frame of the still `data` holds (the PNG ``prepare(_:)`` made), decoded now (off the main actor).
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// The first frame of the still at `file`, decoded now (off the main actor).
    nonisolated static func decode(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Whether `url` is a real folder, not a link to one (a link is never followed).
    nonisolated static func isPlainFolder(_ url: URL) -> Bool {
        (try? FileManager.checked.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// Whether `url` is a real file, not a link.
    nonisolated static func isPlainFile(_ url: URL) -> Bool {
        (try? FileManager.checked.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// Replaces what `directory` holds with `prepared`, worn over `mascot`.
    nonisolated static func write(_ prepared: (still: Data, gif: Data?), over mascot: String, in directory: URL) throws(Refusal) -> Upload {
        // Milliseconds first: the newest upload's name sorts last (``scan(_:)`` takes it).
        let stamp = String(format: "%013d", Int(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString.prefix(8).lowercased()
        let still = directory.appendingPathComponent("\(stamp)-still.png")
        let gif = prepared.gif.map { _ in directory.appendingPathComponent("\(stamp).gif") }
        let manager = FileManager.checked
        let root = directory.deletingLastPathComponent()
        // A link at the uploads folder is refused before anything is made through it.
        if (try? manager.attributesOfItem(atPath: root.path)) != nil, !isPlainFolder(root) { throw .unsaved }
        if (try? manager.attributesOfItem(atPath: directory.path)) == nil {
            do { try manager.createDirectory(at: directory, withIntermediateDirectories: true) } catch { throw .unsaved }
        }
        // Only into real folders: a link at the uploads folder or the key's would send the files (and
        // the old ones' removal) elsewhere.
        guard isPlainFolder(root), isPlainFolder(directory) else { throw .unsaved }
        let old = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        do {
            // The new upload is whole (still, GIF, marker) before the old one goes; a failure leaves the old one.
            try prepared.still.blockingWrite(to: still, options: .atomic)
            if let gif, let data = prepared.gif { try data.blockingWrite(to: gif, options: .atomic) }
            try Data(mascot.utf8).blockingWrite(to: directory.appendingPathComponent(wornMarker), options: .atomic)
        } catch {
            for file in [still, gif].compactMap(\.self) { try? manager.removeItem(at: file) }
            throw .unsaved
        }
        for file in old where file.lastPathComponent != wornMarker { try? manager.removeItem(at: file) }
        return Upload(file: gif ?? still, still: still, wornOver: mascot)
    }

    /// Every upload `folder` holds, with its first frame decoded.
    /// A key whose folder is a link, or whose still is not a real file that decodes, is left out.
    nonisolated static func scan(_ folder: URL) -> [String: (upload: Upload, image: CGImage)] {
        let manager = FileManager.checked
        guard isPlainFolder(folder) else { return [:] }
        let keys = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        var found: [String: (upload: Upload, image: CGImage)] = [:]
        for key in keys where isKey(key) {
            let directory = folder.appendingPathComponent(key, isDirectory: true)
            guard isPlainFolder(directory) else { continue }
            let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            guard let still = names.filter({ $0.hasSuffix("-still.png") }).max() else { continue }
            let stamp = String(still.dropLast("-still.png".count))
            let stillURL = directory.appendingPathComponent(still), gifURL = directory.appendingPathComponent("\(stamp).gif")
            guard isPlainFile(stillURL), let image = decode(stillURL) else { continue }
            let gif = names.contains(gifURL.lastPathComponent) && isPlainFile(gifURL) ? gifURL : nil
            let marker = directory.appendingPathComponent(wornMarker)
            let worn = isPlainFile(marker) ? manager.contents(atPath: marker.path).flatMap { String(data: $0, encoding: .utf8) } : nil
            found[key] = (Upload(file: gif ?? stillURL, still: stillURL, wornOver: worn), image)
        }
        return found
    }
}
