import CmuxNextCompat
import CmuxNextWakeups
import CoreGraphics
import Foundation
import ImageIO
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
/// the preview alone; `{cancelled: true}` when the person presses Esc.
enum AgentPaneCapture {
    nonisolated static let tool = "/usr/sbin/screencapture"
    /// The preview's budget and longest side, as the page fits an attached image
    /// (composer/imageWork.ts `IMAGE_BUDGET_BYTES`, `MAX_IMAGE_SIDE`).
    nonisolated static let previewMaxBytes = 1536 * 1024
    nonisolated static let previewMaxSide = 1568
    /// The most bytes of the original read and staged at once (the page's staged-upload chunk).
    nonisolated static let chunkBytes = 512 * 1024

    /// Runs the pick into the file; false when it could not start (``capture(window:to:)``).
    typealias Pick = @Sendable (_ window: Bool, _ file: URL) async -> Bool

    /// `taken`: when the capture was taken (tests); now, once the pick ends, when nil.
    @MainActor static func reply(to mode: String?, in model: AgentPaneModel, taken: Date? = nil,
                                 pick: Pick = { window, file in await AgentPaneCapture.capture(window: window, to: file) }) async -> [String: Any] {
        guard let mode, mode == "screen" || mode == "window" else { return AgentPaneModel.unsupported("composer.capture") }
        // The screen goes to the agent: only a click in the pane starts a capture. This is the
        // capture's only gesture; saving the original below uses none.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-\(UUID().uuidString).png")
        var result = AgentPaneReply.success(["cancelled": true])
        if await pick(mode == "window", file) { result = await Self.answer(file, taken: taken ?? Date(), in: model) }
        // task-owner: one delete of the capture's temporary file once it is answered; nothing waits for it
        Task.detached(priority: .utility) { try? FileManager.checked.removeItem(at: file) }
        return result
    }

    /// The reply for the capture `screencapture` wrote at `file`, taken at `taken`.
    @MainActor private static func answer(_ file: URL, taken: Date, in model: AgentPaneModel) async -> [String: Any] {
        let name = Self.name(taken: taken)
        // A person waits for the attachment: the file is read and the preview made at userBlocking's
        // priority, off the main actor.
        let (size, preview) = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { () -> (Int, (data: Data, mimeType: String)?) in
            let size = ((try? FileManager.checked.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
            return (size, size > 0 ? Self.preview(of: file, size: size) : nil)
        }.value
        // Esc: `screencapture` wrote nothing.
        guard size > 0 else { return AgentPaneReply.success(["cancelled": true]) }
        let original = await stage(file, name: name, size: size, in: model)
        guard preview != nil || original != nil else {
            return AgentPaneReply.failure(code: "capture_failed", message: "The capture could not be attached.")
        }
        var answer: [String: Any] = ["name": name]
        if let preview {
            answer["mimeType"] = preview.mimeType
            answer["data"] = preview.data.base64EncodedString()
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

    /// Saves `file` as taken through the chat's upload stager (begin, chunks of at most
    /// ``chunkBytes`` read from the file, finish), as the page's staged upload would, without a
    /// gesture of its own: the capture's click already paid for it. The saved path, nil when the
    /// chat's host saves nothing or the save failed (what it staged is cancelled).
    @MainActor static func stage(_ file: URL, name: String, size: Int, in model: AgentPaneModel) async -> String? {
        guard let stager = model.onUploadStage?(), let session = model.sessionId else { return nil }
        let begun = value(await stager(.begin(name: name, size: size, batchToken: nil, batch: nil), session))
        guard let token = begun?["token"] as? String, !token.isEmpty, (begun?["size"] as? NSNumber)?.intValue == size else { return nil }
        let chunk = min((begun?["chunkSize"] as? NSNumber)?.intValue ?? chunkBytes, chunkBytes)
        let cancel = { () async -> String? in
            _ = await stager(.cancel(token: token), session)
            return nil
        }
        guard chunk > 0 else { return await cancel() }
        var offset = 0
        while offset < size {
            let at = offset
            // Read off the main actor: memory stays one chunk, whatever the capture's size.
            let data = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { Self.read(file, at: at, count: min(chunk, size - at)) }.value
            guard let data, !data.isEmpty else { return await cancel() }
            let answer = value(await stager(.chunk(token: token, offset: offset, data: data), session))
            guard (answer?["offset"] as? NSNumber)?.intValue == offset + data.count else { return await cancel() }
            offset += data.count
        }
        guard let path = value(await stager(.finish(token: token), session))?["path"] as? String, path.hasPrefix("/") else { return await cancel() }
        return path
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
    /// stand-in: the original is saved as taken (``stage(_:name:size:in:)``). Nil for bytes that
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

    /// Runs the pick; false when `screencapture` could not start. Its caller is the main actor: the spawn
    /// runs on AsyncProcess's own queue, and the wait holds no thread.
    nonisolated static func capture(window: Bool, to file: URL) async -> Bool {
        // -x: no shutter sound; -o: no window shadow.
        let arguments = (window ? ["-i", "-W", "-o"] : ["-i"]) + ["-x", "-t", "png", file.path]
        return (try? await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: tool), arguments))) != nil
    }
}
