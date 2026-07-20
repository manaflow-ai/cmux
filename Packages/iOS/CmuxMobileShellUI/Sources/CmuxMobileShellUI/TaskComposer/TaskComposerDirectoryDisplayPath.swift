struct TaskComposerDirectoryDisplayPath: Equatable, Sendable {
    let name: String
    let parentPath: String?

    init(path: String) {
        var normalizedPath = path
        while normalizedPath.count > 1, normalizedPath.last == "/" {
            normalizedPath.removeLast()
        }

        guard normalizedPath != "/" else {
            name = "/"
            parentPath = nil
            return
        }

        guard let separator = normalizedPath.lastIndex(of: "/") else {
            name = normalizedPath
            parentPath = nil
            return
        }

        let nameStart = normalizedPath.index(after: separator)
        name = String(normalizedPath[nameStart...])
        let parent = String(normalizedPath[..<separator])
        parentPath = parent.isEmpty ? "/" : parent
    }
}
