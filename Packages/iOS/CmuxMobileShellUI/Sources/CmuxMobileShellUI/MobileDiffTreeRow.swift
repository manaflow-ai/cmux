import Foundation

/// One flattened snapshot row rendered below the changed-files list boundary.
enum MobileDiffTreeRow: Identifiable, Equatable, Sendable {
    case directory(path: String, name: String, depth: Int, fileCount: Int)
    case file(MobileDiffFileChange, depth: Int)

    var id: String {
        switch self {
        case let .directory(path, _, _, _): "directory:\(path)"
        case let .file(file, _): "file:\(file.path)"
        }
    }
}
