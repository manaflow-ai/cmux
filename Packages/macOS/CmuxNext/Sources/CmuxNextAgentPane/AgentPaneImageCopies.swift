import AppKit
import CryptoKit
import Foundation
import CmuxNextCompat

/// The image viewer's Show in Finder and Open in Browser Pane (cx-ncc.39). The viewer holds each
/// image as a `data:` URL, so the host keeps a copy as a file named for the image with its type's
/// extension, in the app's caches (``AgentPaneReplyLinks/imageFolder``): Finder shows it, and a
/// browser pane opens it as `file://`. The same image always maps to the same file.
nonisolated enum AgentPaneImageCopies {
    /// Largest image the actions copy.
    static let maximumBytes = 32 << 20
    /// The image types the actions take, with their extensions. A browser pane never opens an
    /// SVG copy: one could run script from a `file://` page.
    static let extensions: [String: String] = [
        "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
        "image/heic": "heic", "image/tiff": "tiff", "image/bmp": "bmp", "image/svg+xml": "svg",
    ]

    /// A `data:` image's type, from its header alone: nil for another URL or type, or no base64.
    static func type(of src: String) -> String? {
        guard src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") else { return nil }
        let parts = src[src.index(src.startIndex, offsetBy: 5)..<comma].lowercased().split(separator: ";").map(String.init)
        guard let type = parts.first, extensions[type] != nil, parts.contains("base64") else { return nil }
        return type
    }

    /// A `data:` image's bytes and type, nil for another URL, another type or an image too large.
    static func decode(_ src: String) -> (data: Data, type: String)? {
        guard let type = type(of: src), let comma = src.firstIndex(of: ","),
              let data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters),
              !data.isEmpty, data.count <= maximumBytes else { return nil }
        return (data, type)
    }

    /// Longest name part of a copy's file name, in UTF-8 bytes (a file name holds 255).
    static let maximumNameBytes = 200

    /// The copy's file name: the image's name as one plain file name (no folders, no leading dot,
    /// no control or format characters; "Image" when nothing readable is left), a short hash of its
    /// bytes, and its type's extension.
    static func fileName(_ name: String, data: Data, type: String) -> String {
        var base = name.replacingOccurrences(of: "\\.[A-Za-z0-9]{1,5}$", with: "", options: .regularExpression)
        var scalars = String.UnicodeScalarView()
        for scalar in base.unicodeScalars where scalar.properties.generalCategory != .format {
            scalars.append(CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar) ? "-" : scalar)
        }
        base = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".- ").union(.whitespacesAndNewlines))
        if !base.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { base = "Image" }
        while base.utf8.count > maximumNameBytes, !base.isEmpty { base.removeLast() }
        let hash = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(base) \(hash).\(extensions[type] ?? "img")"
    }

    /// Writes `src`'s copy into `folder` (once per image) and returns its file. An SVG is written
    /// only as its rebuilt form (``AgentPaneSVGSanitizer``): a `data:` SVG comes from the reply as
    /// the agent wrote it, and its copy is shown in Finder, saved, dragged out and Quick Looked
    /// outside the pane's `<img>`, where its script and links would count (media-safety R7).
    @concurrent static func copy(_ src: String, name: String, in folder: URL) async -> Result<URL, AgentPaneReplyError> {
        guard var image = decode(src) else { return .failure(.imageRefused) }
        if image.type == "image/svg+xml" {
            guard let clean = AgentPaneSVGSanitizer.sanitize(image.data) else { return .failure(.imageRefused) }
            image.data = clean
        }
        let file = folder.appendingPathComponent(fileName(name, data: image.data, type: image.type), isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? Data(contentsOf: file)) != image.data { try image.data.write(to: file, options: .atomic) }
            return .success(file)
        } catch {
            return .failure(.imageFailed)
        }
    }

    /// The default folder: `Agent Images` in this app's caches.
    static func defaultFolder() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
            .appendingPathComponent("Agent Images", isDirectory: true)
    }
}

extension AgentPaneImageCopies {
    /// The image viewer's actions (``AgentPaneReplyRequest/revealImage(src:name:path:)`` and
    /// ``AgentPaneReplyRequest/openImageInPane(src:name:)``) for `model`'s pane.
    @MainActor static func respond(to request: AgentPaneReplyRequest, in model: AgentPaneModel) async -> [String: Any] {
        switch request {
        case .revealImage(let src, let name, let path): return await reveal(src, name: name, path: path, in: model)
        case .openImageInPane(let src, let name): return await openInPane(src, name: name, in: model)
        case .copyImage(let src, let name):
            return await withCopy(src, name: name, in: model) { file in
                _ = model.replyLinks.copyItem(AgentPaneImageCopies.pasteboardItem(file, image: await AgentPaneImageCopies.pasteboardImage(file)))
            }
        case .saveImage(let src, let name):
            return await withCopy(src, name: name, in: model) { file in
                model.replyLinks.saveFile(file, AgentPaneImageCopies.savedName(name, file: file))
            }
        case .dragImage(let src, let name):
            guard model.replyLinks.mouseHeld() else { return AgentPaneModel.replyFailure(.gestureRequired) }
            switch await copy(src, name: name, in: model.replyLinks.imageFolder) {
            case .success(let file):
                return model.replyLinks.startDrag(file) ? AgentPaneReply.success() : AgentPaneModel.replyFailure(.openFailed)
            case .failure(let error):
                return AgentPaneModel.replyFailure(error)
            }
        case .dragFile(let path):
            guard model.replyLinks.mouseHeld() else { return AgentPaneModel.replyFailure(.gestureRequired) }
            guard let file = draggedFile(path, in: model) else { return AgentPaneModel.replyFailure(.pathInvalid) }
            let out = handedOut(file, in: model.replyLinks.imageFolder)
            if out != file, await !rebuild(file, to: out) { return AgentPaneModel.replyFailure(.imageRefused) }
            return model.replyLinks.startDrag(out) ? AgentPaneReply.success() : AgentPaneModel.replyFailure(.openFailed)
        case .quickLookImage(let src, let name):
            return await withCopy(src, name: name, in: model) { model.replyLinks.quickLookFile($0) }
        default: return AgentPaneModel.replyFailure(.openFailed)
        }
    }

    /// `image.reveal`: the file `path` names when it is one inside the roots of a local chat (not an
    /// SVG, which Finder would open as the agent wrote it), else the image's copy, selected in
    /// Finder. One click covers both.
    @MainActor static func reveal(_ src: String, name: String, path: String?, in model: AgentPaneModel) async -> [String: Any] {
        guard model.transport.gestures.consume() else { return AgentPaneModel.replyFailure(.gestureRequired) }
        if let path, let file = shownFile(path, in: model), handedOut(file, in: model.replyLinks.imageFolder) == file {
            model.replyLinks.revealFile(file)
            return AgentPaneReply.success()
        }
        switch await copy(src, name: name, in: model.replyLinks.imageFolder) {
        case .success(let file):
            model.replyLinks.revealFile(file)
            return AgentPaneReply.success()
        case .failure(let error):
            return AgentPaneModel.replyFailure(error)
        }
    }

    /// The file `path` names when Finder may show it: a file (not a folder) inside the roots, not on
    /// the deny list, in a chat on this machine. Nil otherwise (the image's copy is shown instead).
    @MainActor static func shownFile(_ path: String, in model: AgentPaneModel) -> URL? {
        let paths = model.replyPaths()
        let resolved = AgentPaneReplyPaths.isImagePath(path) ? paths.resolveImage(path) : paths.resolve(path)
        guard !model.remoteChat, let resolved, resolved.place == .root,
              !resolved.isFolder, let canonical = AcpmuxPathPolicy.canonical(resolved.path),
              !paths.isDenied(canonical) else { return nil }
        return URL(fileURLWithPath: canonical, isDirectory: false)
    }

    /// The file `path` names when it may be dragged out: a file or folder inside the roots, not on
    /// the deny list, in a chat on this machine.
    @MainActor static func draggedFile(_ path: String, in model: AgentPaneModel) -> URL? {
        let paths = model.replyPaths()
        let resolved = AgentPaneReplyPaths.isImagePath(path) ? paths.resolveImage(path) : paths.resolve(path)
        guard !model.remoteChat, let resolved, resolved.place == .root,
              let canonical = AcpmuxPathPolicy.canonical(resolved.path),
              !paths.isDenied(canonical) else { return nil }
        return URL(fileURLWithPath: canonical, isDirectory: resolved.isFolder)
    }

    /// The file a path chip hands out (Copy, Save As…, Open With, Reveal in Finder, a drag): the
    /// file itself, or for an SVG its rebuilt copy (``rebuild(_:to:)``), under its own name in a
    /// folder for its path in `folder`. An agent may write the SVG; outside the pane's `<img>` its
    /// script and links would count (media-safety R7). An `.svgz` goes out as on base: the rebuild
    /// reads plain XML only. The folder is named by 16 bytes of the path's hash, so no two paths share it.
    static func handedOut(_ file: URL, in folder: URL) -> URL {
        guard !file.hasDirectoryPath, file.pathExtension.lowercased() == "svg" else { return file }
        let hash = SHA256.hash(data: Data(file.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash, isDirectory: true).appendingPathComponent(file.lastPathComponent, isDirectory: false)
    }

    /// Writes `file`'s rebuilt SVG to `copy` (``handedOut(_:in:)``), off the main actor; false when
    /// the rebuild cannot read it (it is not handed out).
    @concurrent static func rebuild(_ file: URL, to copy: URL) async -> Bool {
        guard let data = regularFileBytes(file, limit: AgentPaneReplyImages.maximumBytes),
              let clean = AgentPaneSVGSanitizer.sanitize(data) else { return false }
        do {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try clean.write(to: copy, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `file`'s bytes when, as it is opened, it is a regular file (not a link, which the agent could
    /// swap in after the path was checked, nor a pipe that would block the read) of at most `limit` bytes.
    nonisolated static func regularFileBytes(_ file: URL, limit: Int) -> Data? {
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let descriptor = unsafe open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        // SAFETY: fstat writes one struct stat into `info`, a local.
        guard unsafe fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try? handle.blockingRead(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    /// Makes each of `items` (and its submenu's) first write `file`'s rebuilt copy to `copy`, then
    /// act; an SVG the rebuild cannot read does nothing but beep.
    @MainActor static func rebuildingFirst(_ items: [NSMenuItem], _ file: URL, to copy: URL) -> [NSMenuItem] {
        for item in items {
            if let submenu = item.submenu { _ = rebuildingFirst(submenu.items, file, to: copy) }
            guard let action = item.action, let target = item.target as? NSObject else { continue }
            let rebuilt = AgentPaneMenuAction { [weak item] in
                // task-owner: one rebuild of a local SVG off the main actor; ends when the row acts
                // main-hop-allow: the person's menu row, userBlocking (p06 rule 2): rebuild runs off main; its one resume
                // performs the row's action on its NSMenuItem, which is main-only and not Sendable
                Task { @MainActor in
                    guard await rebuild(file, to: copy) else { return NSSound.beep() }
                    _ = target.perform(action, with: item)
                }
            }
            item.target = rebuilt
            item.action = #selector(AgentPaneMenuAction.run)
            item.representedObject = rebuilt
        }
        return items
    }

    /// `image.openInPane`: a copy of the `data:` image in a cmux browser pane.
    @MainActor static func openInPane(_ src: String, name: String, in model: AgentPaneModel) async -> [String: Any] {
        guard model.transport.gestures.consume() else { return AgentPaneModel.replyFailure(.gestureRequired) }
        // The type from the header alone: the copy decodes the image off the main actor.
        guard let type = type(of: src), type != "image/svg+xml" else { return AgentPaneModel.replyFailure(.imageRefused) }
        switch await copy(src, name: name, in: model.replyLinks.imageFolder) {
        case .success(let file):
            guard let open = model.onOpenPreview, open(file) else { return AgentPaneModel.replyFailure(.openFailed) }
            return AgentPaneReply.success()
        case .failure(let error):
            return AgentPaneModel.replyFailure(error)
        }
    }
}
