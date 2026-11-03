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
/// Recording permission are the system's.
///
/// The click is one gesture, and the capture uses it. So the host saves the original itself, in
/// that same gesture, through the chat's own upload stager (``AgentPaneModel/onUploadStage``, the
/// one the page's `chat.upload.begin` reaches), a chunk at a time from the file `screencapture`
/// wrote, at any size (Leo, 2026-10-26: attachments have no size cap). It answers
/// `{name, mimeType, data, original: {path, name}}`: `data` is a bounded preview for the model
/// (base64, the PNG itself when it is within ``previewMaxBytes``), `original` where the capture as
/// taken was saved, for the agent to read. The page attaches both as one chip and never sends the
/// bytes back, which would need a second gesture. A chat whose host saves nothing (no stager) gets
/// the preview alone; `{cancelled: true}` when the person presses Esc. A failed original stage
/// reports the retained local file's path instead of silently substituting its preview, and the
/// `capture.failed` error answers a `screencapture` that could not start or ended with an error.
enum AgentPaneCapture {
    nonisolated static let tool = "/usr/sbin/screencapture"
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.capture")
    /// The preview's budget and longest side, as the page fits an attached image
    /// (composer/imageWork.ts `IMAGE_BUDGET_BYTES`, `MAX_IMAGE_SIDE`).
    nonisolated static let previewMaxBytes = 1536 * 1024
    nonisolated static let previewMaxSide = 1568
    /// The most bytes of the original read and staged at once (the page's staged-upload chunk).
    nonisolated static let chunkBytes = 512 * 1024

    /// Runs the pick into the file (``capture(window:to:executable:)``; tests pass a stub).
    typealias Pick = @Sendable (_ window: Bool, _ file: URL) async -> CaptureResult

    /// `taken`: when the capture was taken (tests); now, once the pick ends, when nil.
    @MainActor static func reply(to mode: String?, in model: AgentPaneModel, taken: Date? = nil,
                                 pick: Pick = { window, file in await AgentPaneCapture.capture(window: window, to: file) }) async -> [String: Any] {
        guard let mode, mode == "screen" || mode == "window" else { return AgentPaneModel.unsupported("composer.capture") }
        // The screen goes to the agent: only a click in the pane starts a capture. This is the
        // capture's only gesture; saving the original below uses none.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        // A tab may persist another chat while the system picker or preview is pending.
        // Bind both the route and the optional session to this click before either suspension.
        let stager = model.onUploadStage?()
        let session = model.sessionId
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-\(UUID().uuidString).png")
        if case .failed(let reason) = await pick(mode == "window", file) {
            // ``capture(window:to:executable:)`` already removed any partial file.
            logger.error("composer.capture: screencapture failed: \(reason, privacy: .public)")
            return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
        }
        let result = await Self.answer(file, taken: taken ?? Date(), stager: stager, session: session)
        // A failed/unsupported upload leaves its original at the reported recovery path.
        // Successful/cancelled captures finish their one off-main cleanup before replying.
        if result["ok"] as? Bool == true,
           (result["value"] as? [String: Any])?["originalUnavailable"] == nil {
            await Task.detached(priority: .utility) { try? FileManager.checked.removeItem(at: file) }.value
        }
        return result
    }

    /// The reply for the capture `screencapture` wrote at `file`, taken at `taken`.
    @MainActor private static func answer(_ file: URL, taken: Date, stager: AgentPaneUploadStager?, session: String?) async -> [String: Any] {
        let name = Self.name(taken: taken)
        // A person waits for the attachment: the file is read and the preview made at userBlocking's
        // priority, off the main actor.
        let (size, preview) = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { () -> (Int, (data: Data, mimeType: String)?) in
            let size = ((try? FileManager.checked.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
            return (size, size > 0 ? Self.preview(of: file, size: size) : nil)
        }.value
        // Esc: `screencapture` wrote nothing.
        guard size > 0 else { return AgentPaneReply.success(["cancelled": true]) }
        let staged = await stage(file, name: name, size: size, stager: stager, session: session)
        let original: String? = if case .saved(let path) = staged { path } else { nil }
        guard staged != .failed, preview != nil || original != nil else {
            return AgentPaneReply.failure(
                code: "capture_failed",
                message: "The screenshot could not be attached. Its original was kept at \(file.path).",
                details: ["originalPath": file.path], retryable: false, origin: "native"
            )
        }
        // cmux took it: its chip wears cmux's icon (AttachmentSource).
        var answer: [String: Any] = ["name": name, "source": AttachmentSource.cmux.json]
        if let preview {
            answer["mimeType"] = preview.mimeType
            answer["data"] = preview.data.base64EncodedString()
        }
        if staged == .unsupported, stager != nil {
            answer["originalUnavailable"] = [
                "userMessage": "The screenshot preview was attached. This chat cannot receive the original; it was kept at \(file.path).",
                "originalPath": file.path,
            ]
        }
        if let original { answer["original"] = ["path": original, "name": name] }
        return AgentPaneReply.success(answer)
    }

    /// The capture's name for when it was `taken`, as macOS names its own (so two in one prompt differ).
    nonisolated static func name(taken: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Screenshot \(formatter.string(from: taken)).png"
    }

    private enum Stage: Equatable {
        case saved(String), unsupported, failed
    }

    /// Saves `file` as taken through the chat's upload stager (begin, chunks of at most
    /// ``chunkBytes`` read from the file, finish), as the page's staged upload would, without a
    /// gesture of its own: the capture's click already paid for it. A fresh chat has no session
    /// until its first prompt: the stager is asked for none, and the one for a chat on this Mac
    /// (AgentChatUploads) saves a new chat's upload under Chat Uploads itself; one that needs a
    /// session refuses, and the capture reports failure while retaining its local original.
    /// Older daemons that cannot upload files still receive the preview, with a separate recovery note.
    @MainActor private static func stage(_ file: URL, name: String, size: Int, stager: AgentPaneUploadStager?, session: String?) async -> Stage {
        guard let stager else { return .unsupported }
        let beginReply = await stager(.begin(name: name, size: size, batchToken: nil, batch: nil), session)
        let begun = value(beginReply)
        guard let token = begun?["token"] as? String, !token.isEmpty, (begun?["size"] as? NSNumber)?.intValue == size else { return stageFailure(beginReply) }
        let chunk = min((begun?["chunkSize"] as? NSNumber)?.intValue ?? chunkBytes, chunkBytes)
        let cancel = { (failure: Stage) async -> Stage in
            _ = await stager(.cancel(token: token), session)
            return failure
        }
        guard chunk > 0 else { return await cancel(.failed) }
        var offset = 0
        while offset < size {
            let at = offset
            // Read off the main actor: memory stays one chunk, whatever the capture's size.
            let data = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { Self.read(file, at: at, count: min(chunk, size - at)) }.value
            guard let data, !data.isEmpty else { return await cancel(.failed) }
            let chunkReply = await stager(.chunk(token: token, offset: offset, data: data), session)
            let answer = value(chunkReply)
            guard (answer?["offset"] as? NSNumber)?.intValue == offset + data.count else { return await cancel(stageFailure(chunkReply)) }
            offset += data.count
        }
        let finishReply = await stager(.finish(token: token), session)
        guard let finished = value(finishReply) else { return await cancel(stageFailure(finishReply)) }
        // Local/peer stagers answer path; CloudUploads answers one upload for this one file.
        // Never pick an arbitrary entry from an ambiguous response.
        let path: String?
        if let direct = finished["path"] as? String {
            path = direct
        } else if let uploads = finished["uploads"] as? [[String: Any]], uploads.count == 1 {
            path = uploads[0]["path"] as? String
        } else {
            path = nil
        }
        guard let path, path.hasPrefix("/") else { return await cancel(.failed) }
        return .saved(path)
    }

    private static func stageFailure(_ reply: [String: Any]) -> Stage {
        let error = reply["error"] as? [String: Any]
        return reply["ok"] as? Bool == false && error?["code"] as? String == "unsupported" ? .unsupported : .failed
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
        // -x: no shutter sound; -o: no window shadow.
        let arguments = (window ? ["-i", "-W", "-o"] : ["-i"]) + ["-x", "-t", "png", file.path]
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

    /// A reply's value when it succeeded.
    private static func value(_ reply: [String: Any]) -> [String: Any]? {
        reply["ok"] as? Bool == true ? reply["value"] as? [String: Any] : nil
    }

    /// `count` bytes of `file` from `offset`; nil when they cannot be read.
    nonisolated static func read(_ file: URL, at offset: Int, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return try? handle.blockingRead(upToCount: count)
    }

    /// The model's preview of the PNG at `file` (`size` bytes): the PNG itself within
    /// ``previewMaxBytes``, else scaled to ``previewMaxSide`` as PNG, else as JPEG at falling
    /// quality, the smallest try when none fits (the page fits it further). Never the original's
    /// stand-in: the original is saved as taken (``stage(_:name:size:stager:session:)``). Nil for bytes that
    /// are no image.
    nonisolated static func preview(of file: URL, size: Int) -> (data: Data, mimeType: String)? {
        if size <= previewMaxBytes, let png = try? Data(blockingContentsOf: file) { return (png, "image/png") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewMaxSide,
        ]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let png = encode(image, as: .png), png.count <= previewMaxBytes { return (png, "image/png") }
        var smallest: Data?
        for quality in [0.85, 0.7, 0.5] {
            guard let jpeg = encode(image, as: .jpeg, quality: quality) else { continue }
            if jpeg.count <= previewMaxBytes { return (jpeg, "image/jpeg") }
            if jpeg.count < smallest?.count ?? .max { smallest = jpeg }
        }
        return smallest.map { ($0, "image/jpeg") }
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
