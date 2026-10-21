import CryptoKit
import Foundation

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
        while base.utf8.count > maximumNameBytes { base.removeLast() }
        let hash = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(base) \(hash).\(extensions[type] ?? "img")"
    }

    /// Writes `src`'s copy into `folder` (once per image) and returns its file.
    @concurrent static func copy(_ src: String, name: String, in folder: URL) async -> Result<URL, AgentPaneReplyError> {
        guard let image = decode(src) else { return .failure(.imageRefused) }
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
        default: return AgentPaneModel.replyFailure(.openFailed)
        }
    }

    /// `image.reveal`: the file `path` names when it is one inside the roots of a local chat, else
    /// the image's copy, selected in Finder. One click covers both.
    @MainActor static func reveal(_ src: String, name: String, path: String?, in model: AgentPaneModel) async -> [String: Any] {
        guard model.transport.gestures.consume() else { return AgentPaneModel.replyFailure(.gestureRequired) }
        if let path, let file = shownFile(path, in: model) {
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
        guard !model.remoteChat, let resolved = model.replyPaths().resolve(path), resolved.place == .root,
              !resolved.isFolder, let canonical = AcpmuxPathPolicy.canonical(resolved.path),
              !model.replyPaths().isDenied(canonical) else { return nil }
        return URL(fileURLWithPath: canonical, isDirectory: false)
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
