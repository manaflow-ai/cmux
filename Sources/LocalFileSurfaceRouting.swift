import Foundation

enum LocalFileSurfaceRouting {
    private static let browserRenderableExtensions: Set<String> = [
        "htm",
        "html",
        "shtml",
        "svg",
        "xht",
        "xhtml"
    ]

    static func kind(forFilePath filePath: String) -> LocalFileSurfaceKind {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()

        if ext == "xcodeproj" || ext == "xcworkspace" {
            return .project
        }
        if MarkdownPanelFileLinkResolver.isMarkdownPathLike(filePath) {
            return .markdown
        }
        return .filePreview
    }

    static func browserFileURL(forFilePath filePath: String) -> URL? {
        let url = URL(fileURLWithPath: filePath).standardizedFileURL
        guard browserRenderableExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        return url
    }
}
