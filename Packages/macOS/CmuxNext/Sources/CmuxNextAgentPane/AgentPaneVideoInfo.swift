import AVFoundation
import CmuxNextCompat
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A video's length, size, poster and key frames (`video.info`), for its chip in the composer, its
/// sent bubble and the agent, which cannot watch a video but can look at its frames. Leo,
/// 2026-10-25: "also why dont we have previews of videos we should". The page cannot decode a
/// video itself, so AVFoundation reads it here, off the main actor: only the frames it asks for,
/// never the whole file.
nonisolated enum AgentPaneVideoInfo {
    /// The longest side of the poster, the chip's and the bubble's tile.
    static let posterSide = 320
    /// The longest side of a key frame: as large as a model reads a picture well, without
    /// sending a 4K frame's bytes.
    static let frameSide = 1024
    /// How many key frames a video gives.
    static let frameCount = 4
    /// How far from the asked time a frame may be: the nearest sync frame within it is fast to
    /// decode, and a key frame does not need its exact time.
    static let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
    /// JPEG quality of the poster and frames.
    static let quality = 0.8
    /// The longest side of a frame the page picked (`video.frames`): large enough that an agent
    /// reads a screen recording's text (Leo, 2026-11-01: "i feel like cmux-next should give u better
    /// tools to deal with this kind of thing").
    static let pickedSide = 1280
    /// The most frames one `video.frames` asks for.
    static let maximumPicked = 16
    /// How far from the asked time a picked frame may be: a scene's first frame is near its cut.
    static let pickedTolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
    /// A probe's grid: the video drawn as this many gray cells a side, one byte each, for the page
    /// to find its scene changes (videoFramePick.ts). Its shape is ignored; only change counts.
    static let probeGrid = 24
    /// The fewest and most probes a video gives (two a second between them).
    static let probeRange = 12...48

    struct Frame: Equatable, Sendable {
        /// Where in the video the frame is, in milliseconds.
        var atMs: Int
        /// Its JPEG, base64 (encoded with the read, off the main actor).
        var jpeg: String
    }

    struct Probe: Equatable, Sendable {
        var atMs: Int
        /// ``probeGrid``² gray bytes, row by row, base64.
        var cells: String
    }

    struct Info: Equatable, Sendable {
        var durationMs: Int
        /// The size the video shows at, after its track's rotation.
        var width: Int
        var height: Int
        /// The first key frame's JPEG, base64, at most ``posterSide`` on its longest side.
        var poster: String
        var frames: [Frame]
        var probes: [Probe] = []
        /// Whether the key frames and probes are still to come (`video.probes`, ``keyFrames(_:)``):
        /// the poster's answer (``poster(_:)``) leaves them out so the tile shows at once.
        var more = false

        /// The page's answer: the poster as a `data:` URL, each frame's JPEG as base64 for an
        /// image block, each probe's cells as base64, and `more` when they follow.
        var reply: [String: Any] {
            var reply: [String: Any] = [
                "durationMs": durationMs, "width": width, "height": height,
                "poster": "data:image/jpeg;base64," + poster,
                "frames": frames.map { ["atMs": $0.atMs, "data": $0.jpeg] },
                "probes": probes.map { ["atMs": $0.atMs, "cells": $0.cells] },
            ]
            if more { reply["more"] = true }
            return reply
        }
    }

    /// What follows a video's poster (`video.probes`): its key frames and its probes.
    struct KeyFrames: Equatable, Sendable {
        var frames: [Frame]
        var probes: [Probe]

        /// The page's answer: ``Info/reply``'s `frames` and `probes`.
        var reply: [String: Any] {
            ["frames": frames.map { ["atMs": $0.atMs, "data": $0.jpeg] }, "probes": probes.map { ["atMs": $0.atMs, "cells": $0.cells] }]
        }
    }

    /// The times of `count` key frames of a video `duration` seconds long: the middle of each of
    /// `count` equal parts, so neither the first frame (often black) nor the very last.
    static func frameTimes(duration: Double, count: Int) -> [Double] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        return (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
    }

    /// The asset of the video at `file`, reading only the file's own media: a reference movie's
    /// media in other files (which may be outside the roots, or on the deny list) is refused
    /// (`forbidAll`), so its frames never decode.
    static func ownMedia(_ file: URL) -> AVURLAsset {
        AVURLAsset(url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    }

    /// `asset`'s length in seconds and the size it shows at, after its track's rotation; nil with
    /// no video track or no length.
    static func shape(of asset: AVURLAsset) async -> (seconds: Double, width: Int, height: Int)? {
        guard let duration = try? await asset.load(.duration), let track = try? await asset.loadTracks(withMediaType: .video).first,
              let geometry = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let seconds = duration.seconds
        let shown = CGRect(origin: .zero, size: geometry.0).applying(geometry.1).size
        let width = Int(abs(shown.width).rounded()), height = Int(abs(shown.height).rounded())
        guard seconds.isFinite, seconds > 0, width > 0, height > 0 else { return nil }
        return (seconds, width, height)
    }

    /// The video at `file` (a regular file): its length, size and poster, without its key frames
    /// and probes (``Info/more``; ``keyFrames(_:)`` reads them), or nil when it is not one
    /// AVFoundation can show: no video track, no length, or no frame it can decode. One frame is
    /// decoded, at ``posterSide``, so a dropped video's tile shows at once whatever its length
    /// (Leo, 2026-11-18: "dragging and dropping attachments of any size should never take time to
    /// load. It should just be able to show you the thing"). Only the file's own media is read
    /// (``ownMedia(_:)``).
    @concurrent static func poster(_ file: URL) async -> Info? {
        guard isRegularFile(file) else { return nil }
        let asset = ownMedia(file)
        guard let shape = await shape(of: asset) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: posterSide, height: posterSide)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // The first key frame's time, or the next when it does not decode.
        for time in frameTimes(duration: shape.seconds, count: frameCount) {
            guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
                  let poster = scaled(frame.image, toFit: posterSide).flatMap(jpeg) else { continue }
            return Info(durationMs: Int((shape.seconds * 1000).rounded()), width: shape.width, height: shape.height,
                        poster: poster.base64EncodedString(), frames: [], more: true)
        }
        return nil
    }

    /// What follows the poster of the video at `file` (`video.probes`): ``frameCount`` key frames
    /// at most ``frameSide`` on their longest side, then its probes (``probes(_:duration:)``); nil
    /// when it is not a video AVFoundation can show or none of its key frames decodes. Only the
    /// file's own media is read.
    @concurrent static func keyFrames(_ file: URL) async -> KeyFrames? {
        guard isRegularFile(file) else { return nil }
        let asset = ownMedia(file)
        guard let seconds = await shape(of: asset)?.seconds else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameSide, height: frameSide)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var frames: [Frame] = []
        for time in frameTimes(duration: seconds, count: frameCount) {
            guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
                  let data = jpeg(frame.image) else { continue }
            let at = frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : time
            frames.append(Frame(atMs: Int((min(max(at, 0), seconds) * 1000).rounded()), jpeg: data.base64EncodedString()))
        }
        guard !frames.isEmpty else { return nil }
        return KeyFrames(frames: frames, probes: await probes(file, duration: seconds))
    }

    /// All of the video at `file`: its poster (``poster(_:)``) with its key frames and probes
    /// (``keyFrames(_:)``); nil when either is.
    @concurrent static func read(_ file: URL) async -> Info? {
        guard var info = await poster(file), let rest = await keyFrames(file) else { return nil }
        info.frames = rest.frames
        info.probes = rest.probes
        info.more = false
        return info
    }

    /// The times of a video's probes: two a second, within ``probeRange``, spread as ``frameTimes(duration:count:)``.
    static func probeTimes(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let count = min(max(Int((duration * 2).rounded(.up)), probeRange.lowerBound), probeRange.upperBound)
        return frameTimes(duration: duration, count: count)
    }

    /// Small gray probes of the video at `file`, `duration` seconds long (``Probe``), for the page's
    /// scene pick. Only the file's own media is read, as ``read(_:)`` reads it. A probe that does not
    /// decode is left out.
    @concurrent static func probes(_ file: URL, duration: Double) async -> [Probe] {
        let times = probeTimes(duration: duration)
        guard times.count > 1 else { return [] }
        let asset = AVURLAsset(url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: probeGrid * 4, height: probeGrid * 4)
        // Near the asked time, so a probe never jumps to a sync frame seconds away and hides a cut.
        let tolerance = CMTime(seconds: min(0.25, duration / Double(times.count) / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var probes: [Probe] = []
        for time in times {
            guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
                  let cells = grayCells(frame.image, side: probeGrid) else { continue }
            let at = frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : time
            probes.append(Probe(atMs: Int((min(max(at, 0), duration) * 1000).rounded()), cells: cells.base64EncodedString()))
        }
        return probes
    }

    /// `image` drawn as `side`×`side` gray bytes, row by row.
    static func grayCells(_ image: CGImage, side: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: side * side)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? Data(bytes) : nil
    }

    /// The frames of the video at `file` at `times` (milliseconds, the page's pick), at most
    /// ``pickedSide`` on their longest side, in the order asked; nil when it is not a video
    /// AVFoundation can show. A time that does not decode is left out.
    @concurrent static func frames(_ file: URL, at times: [Int]) async -> [Frame]? {
        guard isRegularFile(file) else { return nil }
        let asset = AVURLAsset(url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0,
              (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return nil }
        let seconds = duration.seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pickedSide, height: pickedSide)
        generator.requestedTimeToleranceBefore = pickedTolerance
        generator.requestedTimeToleranceAfter = pickedTolerance
        var frames: [Frame] = []
        for ms in times.prefix(maximumPicked) {
            let time = min(max(Double(ms) / 1000, 0), seconds)
            guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
                  let data = jpeg(frame.image) else { continue }
            let at = frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : time
            frames.append(Frame(atMs: Int((min(max(at, 0), seconds) * 1000).rounded()), jpeg: data.base64EncodedString()))
        }
        return frames
    }

    /// Whether `file` is a regular file (not a folder named like a movie, nor a pipe).
    static func isRegularFile(_ file: URL) -> Bool {
        (try? file.blockingResourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// The largest video copied byte by byte when the disk cannot clone it (not APFS).
    static let maximumCopyBytes: off_t = 512 << 20
    /// How long a copy may stay in its folder before a later one sweeps it away (one Quick Look
    /// still shows is kept that long).
    static let copyLifetime: TimeInterval = 60 * 60

    /// A private copy of the video file `src` names in `scope` (``AgentPaneReplyPaths/resolveVideo(_:)``),
    /// in a new folder of `parent`: what is read and played is the copy, never the path again, so a
    /// file rewritten in place, replaced, or reached through a folder swapped for a link (to `~/.ssh`)
    /// after its check, and swapped back, gives nothing of another file's. The file is opened once
    /// without following a link, must be a regular file, and the path the system gives for the open
    /// file must be the one checked inside the scope; the copy comes from that open file. On APFS
    /// it is a clone (no bytes copied, and later writes to the file never reach it); elsewhere at
    /// most ``maximumCopyBytes`` are copied.
    /// `matching`, when given, is the file as ``identify(_:in:)`` found it: a file changed since gives no copy.
    @concurrent static func snapshot(_ src: String, in scope: AgentPaneReplyPaths.Scope, into parent: URL,
                                     matching: FileIdentity? = nil) async -> URL? {
        guard case let (descriptor, info, path)? = openChecked(src, in: scope) else { return nil }
        defer { close(descriptor) }
        if let matching, FileIdentity(path: path, info) != matching { return nil }
        sweep(parent)
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent((path as NSString).lastPathComponent, isDirectory: false)
        guard (try? FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        if fclonefileat(descriptor, AT_FDCWD, copy.path, 0) == 0 { return copy }
        guard info.st_size <= maximumCopyBytes, copyBytes(descriptor, to: copy) else {
            try? FileManager.checked.removeItem(at: folder)
            return nil
        }
        return copy
    }

    /// A video file as it is now: where it is, which file it is, and its size and change times. Two
    /// reads of an unchanged file find the same; a file written, replaced or touched since does not.
    struct FileIdentity: Hashable, Sendable {
        var path: String
        var device: Int64
        var inode: UInt64
        var size: Int64
        /// The content's and the inode's last change, in nanoseconds.
        var modified: Int64
        var changed: Int64

        init(path: String, _ info: stat) {
            self.path = path
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            changed = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
        }
    }

    /// The video file `src` names in `scope` as it is now, checked as ``snapshot(_:in:into:matching:)``
    /// checks it, or nil; nothing is copied.
    @concurrent static func identify(_ src: String, in scope: AgentPaneReplyPaths.Scope) async -> FileIdentity? {
        guard case let (descriptor, info, path)? = openChecked(src, in: scope) else { return nil }
        close(descriptor)
        return FileIdentity(path: path, info)
    }

    /// The video file `src` names in `scope` (``AgentPaneReplyPaths/resolveVideo(_:)``) opened once
    /// without following a link: a regular file whose open file the system names by the checked
    /// path. Its descriptor (the caller closes it), its `stat` and that path; nil otherwise.
    private static func openChecked(_ src: String, in scope: AgentPaneReplyPaths.Scope) -> (Int32, stat, String)? {
        guard let resolved = AgentPaneReplyPaths(scope).resolveVideo(src), resolved.place == .root, !resolved.isFolder else { return nil }
        let descriptor = open(resolved.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        var opened = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, fcntl(descriptor, F_GETPATH, &opened) == 0,
              String(decoding: opened.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == resolved.path else {
            close(descriptor)
            return nil
        }
        return (descriptor, info, resolved.path)
    }

    /// Copies the open file `descriptor` to a new file `copy`, byte by byte.
    static func copyBytes(_ descriptor: Int32, to copy: URL) -> Bool {
        let out = open(copy.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { return false }
        defer { close(out) }
        return fcopyfile(descriptor, out, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
    }

    /// Removes the copies in `parent` older than ``copyLifetime``.
    static func sweep(_ parent: URL) {
        let old = Date().addingTimeInterval(-copyLifetime)
        let folders = (try? FileManager.checked.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders where ((try? folder.blockingResourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < old {
            try? FileManager.checked.removeItem(at: folder)
        }
    }

    /// Removes the copy ``snapshot(_:in:into:)`` made, with its folder.
    @concurrent static func discard(_ copy: URL) async {
        try? FileManager.checked.removeItem(at: copy.deletingLastPathComponent())
    }

    /// Whether every track of the video at `file` holds its media in the file itself: a reference
    /// movie's media in other files (outside the roots, or on the deny list) never plays in Quick
    /// Look, which opens a movie with no reference restrictions.
    @concurrent static func isSelfContained(_ file: URL) async -> Bool {
        let asset = AVURLAsset(url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty else { return false }
        for track in tracks {
            guard (try? await track.load(.isSelfContained)) == true else { return false }
        }
        return true
    }

    /// `image` as JPEG at ``quality``.
    static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// `image` drawn at most `side` on its longest side; the image itself when it is already that small. Clear pixels stay
    /// clear (Leo 2026-11-27, ask-3729c9c563: "a fix for the black bg of the preview"): a chat over a see-through ground
    /// keeps its alpha through the scale (it was drawn into a no-alpha context, which made every clear pixel black), so
    /// the card's own fill shows through them. A picture with no alpha stays without one.
    static func scaled(_ image: CGImage, toFit side: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > side else { return image }
        let scale = Double(side) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

extension AgentPaneModel {
    /// A private copy of the video file `src` (a path or `file://` URL) names
    /// (``AgentPaneVideoInfo/snapshot(_:in:into:)``), when the pane may show it: a chat on this
    /// Mac, a regular `.mov`, `.mp4` or `.m4v` file inside the chat's roots, its folder, `/tmp` or
    /// home (where a screen recording lands, as for a reply's image), and not on the deny list. A
    /// chat on another machine names its own files: this Mac's are never read for it. The disk is
    /// read off the main actor.
    func videoSnapshot(_ src: String) async -> URL? {
        guard !chatIsElsewhere else { return nil }
        guard let copy = await AgentPaneVideoInfo.snapshot(src, in: replyPathScope(), into: replyLinks.videoFolder) else { return nil }
        // A chat that turned remote while the disk was read gets nothing (cx-k21v).
        guard !chatIsElsewhere else {
            await AgentPaneVideoInfo.discard(copy)
            return nil
        }
        return copy
    }

    /// The private copy of the video file `src` names that its reads share (``AgentPaneVideoCopies``),
    /// when the pane may show it (the checks of ``videoSnapshot(_:)``), with the file as it was
    /// found; hand it back with ``AgentPaneVideoCopies/release(_:)``. The disk is read off the main actor.
    func sharedVideoCopy(_ src: String) async -> (copy: URL, file: AgentPaneVideoInfo.FileIdentity)? {
        guard !chatIsElsewhere else { return nil }
        let scope = replyPathScope(), folder = replyLinks.videoFolder
        guard let file = await AgentPaneVideoInfo.identify(src, in: scope),
              let copy = await replyLinks.videoCopies.take(file, make: { await AgentPaneVideoInfo.snapshot(src, in: scope, into: folder, matching: file) })
        else { return nil }
        // A chat that turned remote while the disk was read gets nothing (cx-k21v).
        guard !chatIsElsewhere else {
            replyLinks.videoCopies.release(file)
            return nil
        }
        return (copy, file)
    }

    /// `video.info {src}`: the video's length, size and poster (``AgentPaneVideoInfo/poster(_:)``),
    /// with `more`: its key frames and probes follow from `video.probes`. Read from the video's
    /// shared copy.
    func videoInfo(_ src: String) async -> [String: Any] {
        guard let shared = await sharedVideoCopy(src) else { return Self.replyFailure(.mediaRefused) }
        let info = await AgentPaneVideoInfo.poster(shared.copy)
        replyLinks.videoCopies.release(shared.file)
        guard let info, !chatIsElsewhere else { return Self.replyFailure(.mediaRefused) }
        return AgentPaneReply.success(info.reply)
    }

    /// `video.probes {src}`: what follows the video's poster, its key frames and probes
    /// (``AgentPaneVideoInfo/keyFrames(_:)``), read from its shared copy.
    func videoProbes(_ src: String) async -> [String: Any] {
        guard let shared = await sharedVideoCopy(src) else { return Self.replyFailure(.mediaRefused) }
        let rest = await AgentPaneVideoInfo.keyFrames(shared.copy)
        replyLinks.videoCopies.release(shared.file)
        guard let rest, !chatIsElsewhere else { return Self.replyFailure(.mediaRefused) }
        return AgentPaneReply.success(rest.reply)
    }

    /// `video.frames {src, times}`: the video's frames at the times the page picked from its probes
    /// (``AgentPaneVideoInfo/frames(_:at:)``), read from its shared copy.
    func videoFrames(_ src: String, times: [Int]) async -> [String: Any] {
        guard let shared = await sharedVideoCopy(src) else { return Self.replyFailure(.mediaRefused) }
        let frames = await AgentPaneVideoInfo.frames(shared.copy, at: times)
        replyLinks.videoCopies.release(shared.file)
        guard let frames, !chatIsElsewhere else { return Self.replyFailure(.mediaRefused) }
        return AgentPaneReply.success(["frames": frames.map { ["atMs": $0.atMs, "data": $0.jpeg] }])
    }

    /// `video.quickLook {src}`: plays the video's copy in Quick Look, on the person's click. The click
    /// is spent before the file is checked, so a request that waits on the disk never takes a later
    /// one. A reference movie is refused: Quick Look would play the media it points at.
    func quickLookVideo(_ src: String) async -> [String: Any] {
        guard transport.gestures.consume() else { return Self.replyFailure(.gestureRequired) }
        guard let copy = await videoSnapshot(src) else { return Self.replyFailure(.mediaRefused) }
        guard await AgentPaneVideoInfo.isSelfContained(copy), !chatIsElsewhere else {
            await AgentPaneVideoInfo.discard(copy)
            return Self.replyFailure(.mediaRefused)
        }
        replyLinks.quickLookFile(copy)
        return AgentPaneReply.success()
    }
}
