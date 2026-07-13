import Foundation

/// One immutable directory node in the native changed-files tree.
struct MobileDiffTreeDirectory: Equatable, Sendable {
    let path: String
    let name: String
    let directories: [MobileDiffTreeDirectory]
    let files: [MobileDiffFileChange]

    var fileCount: Int {
        files.count + directories.reduce(0) { $0 + $1.fileCount }
    }
}
