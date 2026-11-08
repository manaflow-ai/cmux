import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
import UniformTypeIdentifiers

/// The capture bar's calls (``AgentPaneCaptureCall``): its screenshots and recording, and Copy and
/// Save of what they made. A screenshot spends the person's own click or key in the pane
/// (`gestures.consume()`); a recording's start and a shot of the cmux window or the pane spend the
/// person's fresh click (``AgentPaneCapture/personClicked(_:)``), so a page or an agent can never take one by itself;
/// Copy and Save take only the screenshot this bridge just handed the pane, or a file it wrote
/// (``AgentPaneRecorder/owned(_:)``).
extension AgentPaneCapture {
    @MainActor static func respond(to call: AgentPaneCaptureCall, in model: AgentPaneModel) async -> [String: Any] {
        switch call {
        case .shot(let mode):
            let reply = await reply(to: mode, in: model)
            if let text = (reply["value"] as? [String: Any])?["data"] as? String { await AgentPaneRecorder.shared.handed(text, to: model) }
            return reply
        case .recordStart(let cursor, let clicks):
            guard personClicked(model.transport.gestures) else { return AgentPaneModel.transportFailure(.gestureRequired) }
            guard let window = hostWindow(for: model) else {
                return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
            }
            return await AgentPaneRecorder.shared.start(in: window, for: model, cursor: cursor, clicks: clicks)
        case .recordStop:
            let reply = await AgentPaneRecorder.shared.stop(for: model)
            // The page attaches the movie as a local file link: this chat's video tile and open may read it.
            if let path = (reply["value"] as? [String: Any])?["path"] as? String { model.droppedPaths.retain([path]) }
            return reply
        case .copy(let payload):
            guard await shotIsHanded(payload, to: model) else { return AgentPaneModel.transportFailure(.pathInvalid) }
            return await copy(payload)
        case .done:
            AgentPaneRecorder.shared.spendShot(of: model)
            return AgentPaneReply.success(["done": true])
        case .save(let payload, let name):
            guard await shotIsHanded(payload, to: model) else { return AgentPaneModel.transportFailure(.pathInvalid) }
            return await save(payload, name: name, in: hostWindow(for: model))
        }
    }

    /// Image bytes are only the screenshot this bridge just handed `model`'s page (spent here);
    /// a file is decided by ``AgentPaneRecorder/owned(_:)``.
    @MainActor static func shotIsHanded(_ payload: AgentPaneCapturePayload?, to model: AgentPaneModel) async -> Bool {
        guard case .bytes(let data, _) = payload else { return true }
        return await AgentPaneRecorder.shared.takeShot(data, for: model)
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
            // The file still the one the page was given (no other put at its path since).
            guard let owned = AgentPaneRecorder.shared.owned(path),
                  await Task.detached(priority: WorkPriority.userBlocking.taskPriority, operation: { AgentPaneRecorder.identity(owned.url.path) }).value == owned.identity
            else { return AgentPaneModel.transportFailure(.pathOutsideRoots) }
            item = AgentPaneImageCopies.pasteboardItem(owned.url, data: nil)
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
        let source: URL?, bytes: Data?, expected: AgentPaneRecorder.FileIdentity?
        let suggested: String
        switch payload {
        case .bytes(let data, let mimeType):
            source = nil
            bytes = data
            expected = nil
            suggested = name ?? "Screenshot \(stamp(Date())).\(mimeType == "image/jpeg" ? "jpg" : "png")"
        case .file(let path):
            guard let owned = AgentPaneRecorder.shared.owned(path) else { return AgentPaneModel.transportFailure(.pathOutsideRoots) }
            source = owned.url
            bytes = nil
            expected = owned.identity
            suggested = name ?? owned.url.lastPathComponent
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
            Self.write(bytes: bytes, file: source, expected: expected, to: destination)
        }.value
        guard wrote else { return AgentPaneReply.failure(code: "save_failed", message: AgentPaneModel.captureFailedMessage) }
        return AgentPaneReply.success(["saved": destination.path])
    }

    /// Off the main actor: copies `file` to a new `staged` through descriptors. The source is opened
    /// with `O_NOFOLLOW` and must be a regular file on the open descriptor itself, and the very file
    /// the page was given (`expected`, its device and inode), so a link or another file put in the
    /// movie's place is refused, never followed; `staged` must not exist yet.
    nonisolated static func copyRegular(_ file: URL, expected: AgentPaneRecorder.FileIdentity?, to staged: URL) -> Bool {
        let source = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { return false }
        defer { Darwin.close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              expected.map({ $0 == AgentPaneRecorder.FileIdentity(info) }) ?? true else { return false }
        let target = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard target >= 0 else { return false }
        defer { Darwin.close(target) }
        return fcopyfile(source, target, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
    }

    /// Off the main actor: `bytes`, or a copy of `file`, written beside `destination` and then
    /// moved over it in one atomic rename (the panel asked before replacing), so a failure at any
    /// step leaves the old file whole. Only that partial copy is removed on failure; the movie
    /// itself stays, for Copy and a later Save. A file that is no longer a regular file (a link put
    /// in its place) is refused (``copyRegular(_:to:)``).
    nonisolated static func write(bytes: Data?, file: URL?, expected: AgentPaneRecorder.FileIdentity? = nil, to destination: URL) -> Bool {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        do {
            if let bytes {
                try bytes.blockingWrite(to: staged)
            } else {
                guard let file, copyRegular(file, expected: expected, to: staged) else { throw CocoaError(.fileReadNoPermission) }
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
