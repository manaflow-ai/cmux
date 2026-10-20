import Foundation

/// The project references listed in a workspace's `contents.xcworkspacedata`.
struct XcodeWorkspaceFile {
    enum LoadError: Error, CustomStringConvertible {
        case unknownElement(String)
        case missingLocation(String)

        var description: String {
            switch self {
            case let .unknownElement(name): return "unknown workspace element \(name)"
            case let .missingLocation(name): return "workspace element \(name) has no location"
            }
        }
    }

    /// Every `FileRef` in document order, resolved to a file URL.
    let fileURLs: [URL]

    init(workspaceURL: URL) throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let dataFile = files
            .filter { $0.pathExtension == "xcworkspacedata" }
            .min { $0.lastPathComponent < $1.lastPathComponent }
        let workspaceDir = workspaceURL.deletingLastPathComponent().standardizedFileURL
        guard let dataFile else {
            // A bare workspace is the one Xcode embeds in a project bundle, and it
            // stands for that project.
            fileURLs = [workspaceDir]
            return
        }
        let document = try XMLDocument(contentsOf: dataFile, options: [])
        var urls: [URL] = []
        if let root = document.rootElement() {
            try Self.collect(from: root, groupDir: workspaceDir, workspaceDir: workspaceDir, into: &urls)
        }
        fileURLs = urls
    }

    private static func collect(
        from parent: XMLElement,
        groupDir: URL,
        workspaceDir: URL,
        into urls: inout [URL]
    ) throws {
        for child in parent.children ?? [] {
            guard let element = child as? XMLElement, let name = element.name else { continue }
            guard let location = element.attribute(forName: "location")?.stringValue else {
                throw LoadError.missingLocation(name)
            }
            let url = resolve(location, groupDir: groupDir, workspaceDir: workspaceDir)
            switch name {
            case "FileRef":
                urls.append(url)
            case "Group", "FileSystemSynchronizedGroup":
                try collect(from: element, groupDir: url, workspaceDir: workspaceDir, into: &urls)
            default:
                throw LoadError.unknownElement(name)
            }
        }
    }

    /// `group:` is relative to the enclosing group, `absolute:` stands alone, and
    /// every other kind (`container:`, `self:`) is relative to the workspace's directory.
    private static func resolve(_ location: String, groupDir: URL, workspaceDir: URL) -> URL {
        let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = parts.count == 2 ? String(parts[0]) : ""
        let path = String(parts.last ?? "")
        if kind == "absolute" || path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        let base = kind == "group" ? groupDir : workspaceDir
        if path.isEmpty { return base }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }
}
