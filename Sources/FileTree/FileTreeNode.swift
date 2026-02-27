import Foundation

struct FileTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let isHidden: Bool
    var children: [FileTreeNode]?
    var isExpanded: Bool = false

    var iconName: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }

        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return "swift"
        case "json", "yaml", "yml", "toml":
            return "curlybraces"
        case "md", "txt", "rst":
            return "doc.text"
        case "sh", "zsh", "bash":
            return "terminal"
        case "html", "css", "js", "ts", "tsx", "jsx":
            return "globe"
        case "png", "jpg", "jpeg", "gif", "svg":
            return "photo"
        default:
            return "doc"
        }
    }

    // Hashable conformance excluding children to avoid recursive hashing issues
    static func == (lhs: FileTreeNode, rhs: FileTreeNode) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.path == rhs.path
            && lhs.isDirectory == rhs.isDirectory
            && lhs.isHidden == rhs.isHidden
            && lhs.isExpanded == rhs.isExpanded
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
