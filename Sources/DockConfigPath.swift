import Foundation

/// A normalized absolute POSIX path used for local or remote Dock discovery.
struct DockConfigPath: Hashable, Sendable {
    let value: String

    init?(_ rawValue: String) {
        let expanded = (rawValue as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }

        var components: [Substring] = []
        for component in expanded.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        value = "/" + components.joined(separator: "/")
    }

    func appending(_ relativePath: String) -> DockConfigPath {
        let separator = value == "/" ? "" : "/"
        return DockConfigPath("\(value)\(separator)\(relativePath)")!
    }

    var parent: DockConfigPath? {
        guard value != "/", let slash = value.lastIndex(of: "/") else { return nil }
        let parentValue = slash == value.startIndex ? "/" : String(value[..<slash])
        return DockConfigPath(parentValue)
    }
}
