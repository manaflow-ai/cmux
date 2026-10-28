import CmuxNextWakeups
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The composer's + > Attach Screenshot… and Attach Window… (cx-ncc.71, the Codex app's Attach):
/// `composer.capture {mode: "screen" | "window"}`. After a click in the pane, macOS `screencapture`
/// runs its own region pick (`-i`) or window pick (`-iW`), so the selection UI and the Screen
/// Recording permission are the system's. It answers `{name, mimeType, data}` (base64) for the
/// page to attach as an image, `{tooLarge: true, name}` for one that does not fit the page's cap,
/// or `{cancelled: true}` when the person presses Esc.
enum AgentPaneCapture {
    nonisolated static let tool = "/usr/sbin/screencapture"
    /// The page's cap on an attached image (attachments.ts `MAX_IMAGE_BYTES`).
    nonisolated static let maxBytes = 5 * 1024 * 1024
    /// A Retina capture over the cap is scaled to this longest side first, then sent as JPEG.
    nonisolated static let maxSide = 2560

    @MainActor static func reply(to mode: String?, in model: AgentPaneModel) async -> [String: Any] {
        guard let mode, mode == "screen" || mode == "window" else { return AgentPaneModel.unsupported("composer.capture") }
        // The screen goes to the agent: only a click in the pane starts a capture.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-\(UUID().uuidString).png")
        guard await capture(window: mode == "window", to: file) else { return AgentPaneReply.success(["cancelled": true]) }
        let taken = Date()
        // A person waits for the attachment: the read and the scale run at userBlocking's priority.
        let value = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { () -> [String: any Sendable] in
            defer { try? FileManager.default.removeItem(at: file) }
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
        return ["name": name, "mimeType": image.mimeType, "data": image.data.base64EncodedString()]
    }

    /// Runs the pick; false when `screencapture` could not start. Its caller is the main actor: the spawn
    /// runs on AsyncProcess's own queue, and the wait holds no thread.
    nonisolated static func capture(window: Bool, to file: URL) async -> Bool {
        // -x: no shutter sound; -o: no window shadow.
        let arguments = (window ? ["-i", "-W", "-o"] : ["-i"]) + ["-x", "-t", "png", file.path]
        return (try? await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: tool), arguments))) != nil
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
