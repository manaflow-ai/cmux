import CmuxNextPages
import Foundation
import CmuxNextCompat

/// The markdown page's generated resources: local images of the open file's folder, the diagram
/// libraries, and remote images the host fetches after the reader approves this document.
extension FilePageProvider {
    // MARK: Resources (markdown)

    nonisolated static let localImageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "avif": "image/avif", "ico": "image/x-icon", "bmp": "image/bmp",
    ]
    nonisolated static let localImageLimit = 50 * 1024 * 1024

    func resource(for request: PageResourceRequest) async -> PageResource? {
        guard kind == .markdown, !isClosed else { return nil }
        switch request.prefix {
        case MarkdownPageResource.asset:
            guard let file, request.path.count >= 2, request.path[0] == assetToken else { return nil }
            let folder = file.deletingLastPathComponent()
            let relative = request.path.dropFirst().joined(separator: "/")
            let image = try? await work.runFiles(.userVisible) { Self.localImage(folder: folder, relative: relative) }
            return image ?? nil
        case MarkdownPageResource.library:
            guard let libraries, request.path.count == 1,
                  let data = await MarkdownPageResource.library(request.path[0], in: libraries, runner: work) else { return nil }
            return PageResource(data: data, mimeType: "text/javascript; charset=utf-8")
        case MarkdownPageResource.remoteImage:
            guard remoteImagesAllowed, request.path.count == 2, request.path[0] == remoteImageToken,
                  let url = RemoteImagePolicy.decode(request.path[1]),
                  RemoteImagePolicy.allows(url) else { return nil }
            return await images.fetch(url)
        default:
            return nil
        }
    }

    /// Blocking file calls: the files lane only.
    nonisolated private static func localImage(folder: URL, relative: String) -> PageResource? {
        let real = folder.appending(path: relative).standardizedFileURL.resolvingSymlinksInPath()
        let base = folder.resolvingSymlinksInPath().path
        guard real.path.hasPrefix(base + "/"), let type = localImageTypes[real.pathExtension.lowercased()],
              let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= localImageLimit,
              let data = try? Data(contentsOf: real) else { return nil }
        return PageResource(data: data, mimeType: type)
    }
}
