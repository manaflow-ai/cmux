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

    /// A `data:` image's bytes and type, nil for another URL, another type or an image too large.
    static func decode(_ src: String) -> (data: Data, type: String)? {
        guard src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") else { return nil }
        let header = src[src.index(src.startIndex, offsetBy: 5)..<comma].lowercased()
        let parts = header.split(separator: ";").map(String.init)
        guard let type = parts.first, extensions[type] != nil, parts.contains("base64"),
              let data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters),
              !data.isEmpty, data.count <= maximumBytes else { return nil }
        return (data, type)
    }

    /// The copy's file name: the image's name as one plain file name (no folders, no leading dot,
    /// "Image" when it has none), a short hash of its bytes, and its type's extension.
    static func fileName(_ name: String, data: Data, type: String) -> String {
        var base = name.replacingOccurrences(of: "\\.[A-Za-z0-9]{1,5}$", with: "", options: .regularExpression)
        base = String(base.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar) ? "-" : Character(scalar)
        })
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if base.isEmpty { base = "Image" }
        let hash = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(base.prefix(80)) \(hash).\(extensions[type] ?? "img")"
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
    /// The image viewer's actions (``AgentPaneReplyRequest/revealImage(src:name:)`` and
    /// ``AgentPaneReplyRequest/openImageInPane(src:name:)``) for `model`'s pane.
    @MainActor static func respond(to request: AgentPaneReplyRequest, in model: AgentPaneModel) async -> [String: Any] {
        switch request {
        case .revealImage(let src, let name): return await reveal(src, name: name, in: model)
        case .openImageInPane(let src, let name): return await openInPane(src, name: name, in: model)
        default: return AgentPaneModel.replyFailure(.openFailed)
        }
    }

    /// `image.reveal`: the image's own file when `src` names one inside the roots (a local chat),
    /// else its copy, selected in Finder.
    @MainActor static func reveal(_ src: String, name: String, in model: AgentPaneModel) async -> [String: Any] {
        guard model.transport.gestures.consume() else { return AgentPaneModel.replyFailure(.gestureRequired) }
        if !src.hasPrefix("data:") {
            guard !model.remoteChat else { return AgentPaneModel.replyFailure(.pathInvalid) }
            guard let resolved = model.replyPaths().resolve(src) else { return AgentPaneModel.replyFailure(.pathInvalid) }
            switch resolved.place {
            case .root: break
            case .denied: return AgentPaneModel.replyFailure(.pathDenied)
            case .outside: return AgentPaneModel.replyFailure(.pathOutsideRoots)
            case .missing: return AgentPaneModel.replyFailure(.pathInvalid)
            }
            guard !resolved.isFolder, let canonical = AcpmuxPathPolicy.canonical(resolved.path),
                  !model.replyPaths().isDenied(canonical) else { return AgentPaneModel.replyFailure(.pathInvalid) }
            model.replyLinks.revealFile(URL(fileURLWithPath: canonical, isDirectory: false))
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

    /// `image.openInPane`: a copy of the `data:` image in a cmux browser pane.
    @MainActor static func openInPane(_ src: String, name: String, in model: AgentPaneModel) async -> [String: Any] {
        guard model.transport.gestures.consume() else { return AgentPaneModel.replyFailure(.gestureRequired) }
        guard let image = AgentPaneImageCopies.decode(src), image.type != "image/svg+xml" else {
            return AgentPaneModel.replyFailure(.imageRefused)
        }
        switch await copy(src, name: name, in: model.replyLinks.imageFolder) {
        case .success(let file):
            guard let open = model.onOpenPreview, open(file) else { return AgentPaneModel.replyFailure(.openFailed) }
            return AgentPaneReply.success()
        case .failure(let error):
            return AgentPaneModel.replyFailure(error)
        }
    }
}
