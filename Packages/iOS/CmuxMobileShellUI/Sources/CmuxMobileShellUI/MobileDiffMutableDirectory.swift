import Foundation

/// Mutable construction node kept private to native diff-tree assembly.
final class MobileDiffMutableDirectory {
    let path: String
    let name: String
    var directories: [MobileDiffMutableDirectory] = []
    var files: [MobileDiffFileChange] = []

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}
