import Dispatch
import Foundation

struct LocalDockConfigFileSystem: DockConfigFileSystem {
    func metadata(at path: String, deadline: DispatchTime) async throws -> DockConfigFileMetadata {
        try await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return DockConfigFileMetadata(exists: false, kind: nil, size: nil)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let kind: DockConfigFileMetadata.Kind
            if isDirectory.boolValue {
                kind = .directory
            } else if attributes[.type] as? FileAttributeType == .typeRegular {
                kind = .file
            } else {
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
