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
/// page to attach as an image, `{tooLarge: true, name}` for one that does not fit the page's cap,
/// `{cancelled: true}` when the person presses Esc, or the `capture.failed` error when
/// `screencapture` could not start or ended with an error.
enum AgentPaneCapture {
    nonisolated static let tool = "/usr/sbin/screencapture"
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.capture")
    /// The page's cap on an attached image (attachments.ts `MAX_IMAGE_BYTES`).
    nonisolated static let maxBytes = 5 * 1024 * 1024
    /// A Retina capture over the cap is scaled to this longest side first, then sent as JPEG.
    nonisolated static let maxSide = 2560

    @MainActor static func reply(to mode: String?, in model: AgentPaneModel) async -> [String: Any] {
        guard let mode, mode == "screen" || mode == "window" else { return AgentPaneModel.unsupported("composer.capture") }
        // The screen goes to the agent: only a click in the pane starts a capture.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-\(UUID().uuidString).png")
        if case .failed(let reason) = await capture(window: mode == "window", to: file) {
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

    /// The page's answer for the bytes `screencapture` wrote: the image named for when it was
    /// `taken` (as macOS names its own, so two in one prompt differ), `tooLarge` with that name when
    /// even a scaled copy is over the cap, `cancelled` for none (Esc).
    nonisolated static func answer(_ png: Data, taken: Date) -> [String: any Sendable] {
        guard !png.isEmpty else { return ["cancelled": true] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = "Screenshot \(formatter.string(from: taken))"
        guard let image = fit(png) else { return ["tooLarge": true, "name": "\(stem).png"] }
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
