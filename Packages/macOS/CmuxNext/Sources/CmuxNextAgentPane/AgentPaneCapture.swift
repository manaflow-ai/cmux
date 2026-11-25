import CmuxNextCompat
import CmuxNextWakeups
import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// The composer's + > Attach Screenshot… and Attach Window… (cx-ncc.71, the Codex app's Attach):
/// `composer.capture {mode: "screen" | "window"}`. After a click in the pane, macOS `screencapture`
/// runs its own region pick (`-i`) or window pick (`-iW`), so the selection UI and the Screen
/// Recording permission are the system's. It answers `{name, mimeType, data}` (base64) for the
/// page to attach as an image (never refused for its size), `{cancelled: true}` when the person
/// presses Esc, or the `capture.failed` error when `screencapture` could not start or ended with an
/// error.
///
/// + > Record Screen… (`{mode: "video"}`, Leo, 2026-11-07: "could we also have a more native
/// screenshot/screensharer (ergonomic one)/video recording of the app type thing/route?") opens the
/// system's own Screenshot toolbar in its video mode (`-iU -J video`, the ⌘⇧5 one): the person picks
/// the cmux window, a region or the screen, records, and stops from the menu bar. The movie is kept in
/// ~/Movies/cmux (it is the person's, to send or share, and the agent reads it there) and answers
/// `{path, name, mimeType, source}` for the page to attach as a video link chip (its poster, frames
/// and speech come from `video.info`). A still taken from that toolbar instead answers as a screenshot.
/// This file is the thin native seam the platform needs: the capture UI and permission are macOS's.
enum AgentPaneCapture {
    nonisolated static let tool = "/usr/sbin/screencapture"
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.capture")
    /// The size a capture is scaled toward (attachments.ts `MAX_IMAGE_BYTES`); one still over it goes
    /// as written, and the page saves that original to the chat beside its own preview.
    nonisolated static let maxBytes = 5 * 1024 * 1024
    /// A Retina capture over the cap is scaled to this longest side first, then sent as JPEG.
    nonisolated static let maxSide = 2560

    @MainActor static func reply(to mode: String?, in model: AgentPaneModel) async -> [String: Any] {
        guard let mode, let pick = Pick(rawValue: mode) else { return AgentPaneModel.unsupported("composer.capture") }
        // The screen goes to the agent: only a click in the pane starts a capture.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        if pick == .video { return await recordReply() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-\(UUID().uuidString).png")
        if case .failed(let reason) = await capture(window: pick == .window, to: file) {
            logger.error("composer.capture: screencapture failed: \(reason, privacy: .public)")
            return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
        }
        let taken = Date()
        // A person waits for the attachment: the read and the scale run at userBlocking's priority.
        let value = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { () -> [String: any Sendable] in
            defer { try? FileManager.checked.removeItem(at: file) }
            return Self.answer((try? Data(contentsOf: file)) ?? Data(), taken: taken)
        }.value
        return AgentPaneReply.success(value)
    }

    /// What the page asked for: a region, a window, or a recording.
    nonisolated enum Pick: String, Sendable {
        case screen, window, video
    }

    /// Record Screen…: the toolbar's recording, kept in ``recordingsFolder``; a still from the
    /// toolbar answers as Attach Screenshot's does; nothing written (Esc, the toolbar closed) cancels.
    @MainActor private static func recordReply() async -> [String: Any] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-recording-\(UUID().uuidString).mov")
        if case .failed(let reason) = await capture(arguments: arguments(for: .video, to: file), to: file) {
            logger.error("composer.capture: screen recording failed: \(reason, privacy: .public)")
            return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
        }
        let taken = Date()
        let value = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { () -> [String: any Sendable] in
            Self.keepRecording(file, taken: taken, in: Self.recordingsFolder())
        }.value
        return AgentPaneReply.success(value)
    }

    /// Where recordings are kept: ~/Movies/cmux, the person's to find, send and share.
    nonisolated static func recordingsFolder() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("cmux", isDirectory: true)
    }

    /// The page's answer for what the toolbar wrote at `file`: `cancelled` for nothing, a still as
    /// ``answer(_:taken:)`` (the temporary file removed), else the movie moved into `folder` as
    /// "Screen Recording <when>.mov" (a name already there gets a number) and its `path`.
    nonisolated static func keepRecording(_ file: URL, taken: Date, in folder: URL) -> [String: any Sendable] {
        let size = (try? FileManager.checked.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            try? FileManager.checked.removeItem(at: file)
            return ["cancelled": true]
        }
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetType(source) != nil,
           CGImageSourceGetCount(source) > 0 {
            defer { try? FileManager.checked.removeItem(at: file) }
            return answer((try? Data(blockingContentsOf: file)) ?? Data(), taken: taken)
        }
        let stem = "Screen Recording \(stamp(taken))"
        do {
            try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
            var kept = folder.appendingPathComponent("\(stem).mov")
            var copy = 2
            while FileManager.checked.fileExists(atPath: kept.path) {
                kept = folder.appendingPathComponent("\(stem) \(copy).mov")
                copy += 1
            }
            try FileManager.checked.moveItem(at: file, to: kept)
            return ["path": kept.path, "name": kept.lastPathComponent, "mimeType": "video/quicktime",
                    "source": AttachmentSource.cmux.json]
        } catch {
            // The movie stays where the toolbar wrote it: still the person's recording, still readable.
            logger.error("composer.capture: could not keep the recording: \(String(describing: error), privacy: .public)")
            return ["path": file.path, "name": file.lastPathComponent, "mimeType": "video/quicktime",
                    "source": AttachmentSource.cmux.json]
        }
    }

    /// `screencapture`'s arguments for `pick`, writing to `file`. A still: -i the region pick (-W the
    /// window pick, -o without its shadow), -x no shutter sound, -t png. A recording: -i -U the
    /// system toolbar, -J video starting in its video mode, -k showing clicks (what a problem report
    /// needs to show), -x.
    nonisolated static func arguments(for pick: Pick, to file: URL) -> [String] {
        switch pick {
        case .screen: ["-i", "-x", "-t", "png", file.path]
        case .window: ["-i", "-W", "-o", "-x", "-t", "png", file.path]
        case .video: ["-i", "-U", "-J", "video", "-k", "-x", file.path]
        }
    }

    private nonisolated static func stamp(_ taken: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: taken)
    }

    /// The page's answer for the bytes `screencapture` wrote: the image named for when it was
    /// `taken` (as macOS names its own, so two in one prompt differ), the PNG as written when even a
    /// scaled copy is over ``maxBytes`` (no capture is refused for its size), `cancelled` for none (Esc).
    nonisolated static func answer(_ png: Data, taken: Date) -> [String: any Sendable] {
        guard !png.isEmpty else { return ["cancelled": true] }
        let stem = "Screenshot \(stamp(taken))"
        let image = fit(png) ?? (data: png, mimeType: "image/png")
        let name = image.mimeType == "image/png" ? "\(stem).png" : "\(stem).jpg"
        // cmux took it: its chip wears cmux's icon (AttachmentSource).
        return ["name": name, "mimeType": image.mimeType, "data": image.data.base64EncodedString(),
                "source": AttachmentSource.cmux.json]
    }

    /// What one pick produced.
    nonisolated enum CaptureResult: Equatable, Sendable {
        /// `screencapture` ran; its file holds the image, or nothing (Esc).
        case taken
        /// It could not start or ended with an error, in the system's words.
        case failed(String)
    }

    /// Runs the pick with `executable` (``tool``; tests pass a stub); `.failed` when it could not start.
    /// Its caller is the main actor, so it runs off it (`@concurrent`): the spawn runs on AsyncProcess's own
    /// queue, the wait holds no thread, and the file check and cleanup never touch the disk on the main thread.
    @concurrent nonisolated static func capture(window: Bool, to file: URL, executable: String = tool) async -> CaptureResult {
        await capture(arguments: arguments(for: window ? .window : .screen, to: file), to: file, executable: executable)
    }

    /// Runs `executable` with `arguments` (``arguments(for:to:)``) that write `file`; as ``capture(window:to:executable:)``.
    @concurrent nonisolated static func capture(arguments: [String], to file: URL, executable: String = tool) async -> CaptureResult {
        let result: CaptureResult
        do {
            let outcome = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: executable), arguments,
                                                                      errorOutput: .separate))
            let said = String(decoding: outcome.errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // With a file, the status decides (0: the image). With none, an Esc says nothing, whatever
            // status the macOS version gives it, and an end that says why is an error (no Screen
            // Recording grant). A signal is always an error (a crash).
            let wrote = FileManager.checked.fileExists(atPath: file.path)
            let ok = outcome.exited && (wrote ? outcome.status == 0 : said.isEmpty)
            result = ok ? .taken
                : .failed("\(said.isEmpty ? "no message" : said) (\(outcome.exited ? "exit" : "signal") \(outcome.status))")
        } catch {
            result = .failed(String(describing: error))
        }
        // A failed pick's partial file is the person's screen: never left in the temp folder.
        if result != .taken { try? FileManager.checked.removeItem(at: file) }
        return result
    }

    /// The capture as an image under ``maxBytes``: the PNG as written, else scaled to ``maxSide`` as
    /// PNG, else as JPEG; nil for an empty file (Esc) or an image that still does not fit.
    nonisolated static func fit(_ png: Data) -> (data: Data, mimeType: String)? {
        guard !png.isEmpty else { return nil }
        if png.count <= maxBytes { return (png, "image/png") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let scaled = encode(image, as: .png), scaled.count <= maxBytes { return (scaled, "image/png") }
        if let jpeg = encode(image, as: .jpeg, quality: 0.85), jpeg.count <= maxBytes { return (jpeg, "image/jpeg") }
        return nil
    }

    private nonisolated static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let properties = quality.map { quality -> CFDictionary in
            let lossy: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            return lossy as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
