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

    /// Every `FileRef` location in document order, with the `group:`,
    /// `container:`, `absolute:` or `self:` prefix removed.
    let fileLocations: [String]

    init(workspaceURL: URL) throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let dataFile = files
            .filter { $0.pathExtension == "xcworkspacedata" }
            .min { $0.lastPathComponent < $1.lastPathComponent }
        guard let dataFile else {
            fileLocations = []
            return
        }
        let document = try XMLDocument(contentsOf: dataFile, options: [])
        var locations: [String] = []
        if let root = document.rootElement() {
            try Self.collect(from: root, into: &locations)
        }
        fileLocations = locations
    }

    private static func collect(from parent: XMLElement, into locations: inout [String]) throws {
        for child in parent.children ?? [] {
            guard let element = child as? XMLElement, let name = element.name else { continue }
            guard let location = element.attribute(forName: "location")?.stringValue else {
                throw LoadError.missingLocation(name)
            }
            switch name {
            case "FileRef":
                let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                locations.append(String(parts.last ?? ""))
            case "Group", "FileSystemSynchronizedGroup":
                try collect(from: element, into: &locations)
            default:
                throw LoadError.unknownElement(name)
            }
        }
    }
}
