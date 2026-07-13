import Foundation

/// Preserves status order while grouping file snapshots into directory nodes.
struct MobileDiffTreeBuilder {
    let root = MobileDiffMutableDirectory(path: "", name: "")

    init(files: [MobileDiffFileChange]) {
        for file in files {
            insert(file)
        }
    }

    func freeze(_ directory: MobileDiffMutableDirectory) -> MobileDiffTreeDirectory {
        MobileDiffTreeDirectory(
            path: directory.path,
            name: directory.name,
            directories: directory.directories.map(freeze),
            files: directory.files
        )
    }

    private func insert(_ file: MobileDiffFileChange) {
        let components = file.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count > 1 else {
            root.files.append(file)
            return
        }

        var parent = root
        var pathComponents: [String] = []
        for name in components.dropLast() {
            pathComponents.append(name)
            let path = pathComponents.joined(separator: "/")
            if let existing = parent.directories.first(where: { $0.name == name }) {
                parent = existing
            } else {
                let directory = MobileDiffMutableDirectory(path: path, name: name)
                parent.directories.append(directory)
                parent = directory
            }
        }
        parent.files.append(file)
    }
}
