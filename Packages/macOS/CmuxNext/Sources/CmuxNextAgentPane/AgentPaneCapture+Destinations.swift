import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
import UniformTypeIdentifiers

/// The capture bar's calls (``AgentPaneCaptureCall``): its screenshots and recording, and Copy and
/// Save of what they made. A screenshot and a recording's start spend the person's own click or
/// key in the pane (`gestures.consume()`), so a page or an agent can never take one by itself;
/// Copy and Save take only an image's bytes or a file this bridge wrote (``AgentPaneRecorder/owned(_:)``).
extension AgentPaneCapture {
    @MainActor static func respond(to call: AgentPaneCaptureCall, in model: AgentPaneModel) async -> [String: Any] {
        switch call {
        case .shot(let mode): return await reply(to: mode, in: model)
        case .recordStart(let cursor, let clicks):
            guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
            guard let window = hostWindow(for: model) else {
                return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
            }
            return await AgentPaneRecorder.shared.start(in: window, for: model, cursor: cursor, clicks: clicks)
        case .recordStop:
            let reply = await AgentPaneRecorder.shared.stop()
            // The page attaches the movie as a local file link: this chat's video tile and open may read it.
            if let path = (reply["value"] as? [String: Any])?["path"] as? String { model.droppedPaths.retain([path]) }
            return reply
        case .copy(let payload): return await copy(payload)
        case .save(let payload, let name): return await save(payload, name: name, in: hostWindow(for: model))
        }
    }

    /// `capture.copy`: the image's bytes (under its type and as TIFF), or a recording's file URL,
    /// replace the general pasteboard's contents, as Finder's Copy does. `{copied: true}`.
    @MainActor static func copy(_ payload: AgentPaneCapturePayload?) async -> [String: Any] {
        let item: NSPasteboardItem
        switch payload {
        case .bytes(let data, let mimeType):
            item = NSPasteboardItem()
            let type = UTType(mimeType: mimeType) ?? .png
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            // The TIFF for apps that read only that, decoded off the main actor.
            let tiff = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { NSBitmapImageRep(data: data)?.tiffRepresentation }.value
            if let tiff { item.setData(tiff, forType: .tiff) }
        case .file(let path):
            guard let file = AgentPaneRecorder.shared.owned(path) else { return AgentPaneModel.transportFailure(.pathOutsideRoots) }
            item = AgentPaneImageCopies.pasteboardItem(file, data: nil)
        case nil:
            return AgentPaneModel.transportFailure(.pathInvalid)
        }
        guard AgentPaneImageCopies.writeGeneral(item) else {
            return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
        }
        return AgentPaneReply.success(["copied": true])
    }

    /// `capture.save`: the save panel as a sheet on the host window (never an app-modal loop),
    /// then the image's bytes or the recording's copy at the chosen place. `{saved: path}`, or
    /// `{cancelled: true}` for a cancelled panel or one already up.
    @MainActor static func save(_ payload: AgentPaneCapturePayload?, name: String?, in window: NSWindow?) async -> [String: Any] {
        let source: URL?, bytes: Data?
        let suggested: String
        switch payload {
        case .bytes(let data, let mimeType):
            source = nil
            bytes = data
            suggested = name ?? "Screenshot \(stamp(Date())).\(mimeType == "image/jpeg" ? "jpg" : "png")"
        case .file(let path):
            guard let file = AgentPaneRecorder.shared.owned(path) else { return AgentPaneModel.transportFailure(.pathOutsideRoots) }
            source = file
            bytes = nil
            suggested = name ?? file.lastPathComponent
        case nil:
            return AgentPaneModel.transportFailure(.pathInvalid)
        }
        let recorder = AgentPaneRecorder.shared
        guard !recorder.saving else { return AgentPaneReply.success(["cancelled": true]) }
        recorder.saving = true
        defer { recorder.saving = false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let chosen = await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            panel.beginForCmux(in: window) { done.resume(returning: $0) }
        }
        guard let destination = chosen else { return AgentPaneReply.success(["cancelled": true]) }
        let wrote = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) {
            Self.write(bytes: bytes, file: source, to: destination)
        }.value
        guard wrote else { return AgentPaneReply.failure(code: "save_failed", message: AgentPaneModel.captureFailedMessage) }
        return AgentPaneReply.success(["saved": destination.path])
    }

    /// Off the main actor: `bytes`, or a copy of `file`, written beside `destination` and then
    /// moved over it in one atomic rename (the panel asked before replacing), so a failure at any
    /// step leaves the old file whole. Only that partial copy is removed on failure; the movie
    /// itself stays, for Copy and a later Save. A file that is no longer a regular file (a link put
    /// in its place) is refused.
    nonisolated static func write(bytes: Data?, file: URL?, to destination: URL) -> Bool {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        do {
            if let bytes {
                try bytes.blockingWrite(to: staged)
            } else {
                guard let file, (try? FileManager.checked.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular else { return false }
                try FileManager.checked.copyItem(at: file, to: staged)
            }
            // rename(2) replaces an existing destination atomically (both are in its folder).
            guard rename(staged.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            return true
        } catch {
            try? FileManager.checked.removeItem(at: staged)
            return false
        }
    }
}
