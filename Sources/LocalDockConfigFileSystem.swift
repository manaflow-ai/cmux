import Dispatch
import Foundation

struct LocalDockConfigFileSystem: DockConfigFileSystem {
    func metadata(at path: String, deadline: DispatchTime) async throws -> DockConfigFileMetadata {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: path) else {
                return DockConfigFileMetadata(exists: false, kind: nil, size: nil)
            }
            let linkAttributes = try fileManager.attributesOfItem(atPath: path)
            let attributes: [FileAttributeKey: Any]
            if linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                attributes = try fileManager.attributesOfItem(atPath: resolvedPath)
            } else {
                attributes = linkAttributes
            }
            let kind: DockConfigFileMetadata.Kind
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                kind = .directory
            case .typeRegular:
                kind = .file
            default:
                kind = .other
            }
            return DockConfigFileMetadata(
                exists: true,
                kind: kind,
                size: (attributes[.size] as? NSNumber)?.int64Value
            )
        }.value
    }

    func readFile(at path: String, deadline: DispatchTime) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false))
        }.value
    }
}
