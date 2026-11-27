public import Foundation
import AppKit
import CmuxNextDesign

/// The pasteboard handed to the Rust transfer client. File contents are read
/// there; only a pasteboard image is materialized by the native pasteboard.
public nonisolated struct TerminalFilePaste: Sendable, Encodable {
    public struct Image: Sendable, Encodable {
        public var mime: String
        public var data: Data
    }

    public var files: [String]?
    public var image: Image?
}

extension TerminalSession {
    /// True means the transfer owns this paste, including any eventual failure.
    /// It must never fall through to inserting a path from this Mac.
    func handOffFilePaste(_ pasteboard: NSPasteboard) -> Bool {
        guard io.uploadsPasteboardFiles else { return false }
        return handOffFilePaste(TerminalPasteboardContents(pasteboard: pasteboard))
    }

    func handOffFilePaste(_ contents: TerminalPasteboardContents) -> Bool {
        guard io.uploadsPasteboardFiles else { return false }
        let payload: TerminalFilePaste
        if !contents.fileURLs.isEmpty {
            payload = TerminalFilePaste(files: contents.fileURLs.map(\.path))
        } else if TerminalPasteboard.pasteText(from: contents)?.isEmpty ?? true,
                  let image = TerminalPasteboard.imageData(from: contents) {
            payload = TerminalFilePaste(image: .init(mime: image.fileExtension == "jpg" ? "image/jpeg" : "image/png", data: image.data))
        } else {
            return false
        }
        enqueueFilePaste(payload)
        return true
    }

    func filePasteFailed() {
        guard !isClosed, surfaceView.window != nil else { return }
        let spec = CmuxDialogSpec(
            title: String(localized: "terminal.filePaste.failed.title", defaultValue: "Couldn’t paste the file", table: "TerminalFilePaste", bundle: .module),
            lines: [String(localized: "terminal.filePaste.failed.message", defaultValue: "The upload could not be confirmed. Check the terminal before pasting again.", table: "TerminalFilePaste", bundle: .module)],
            buttons: [.init(id: "ok", title: String(localized: "terminal.filePaste.failed.dismiss", defaultValue: "Close", table: "TerminalFilePaste", bundle: .module), role: .cancel)])
        CmuxDialogCenter.shared.present(spec, in: .tab(surfaceView)) { _ in }
    }
}
