import Foundation

/// A normalized forward-slash split of one repository-relative path.
struct MobileDiffPath: Equatable, Sendable {
    let components: [String]

    init(_ path: String) {
        components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    var fileName: String {
        components.last ?? ""
    }

    var directory: String {
        components.dropLast().joined(separator: "/")
    }

    var ancestorDirectories: [String] {
        var ancestors: [String] = []
        var componentsSoFar: [String] = []
        for component in components.dropLast() {
            componentsSoFar.append(component)
            ancestors.append(componentsSoFar.joined(separator: "/"))
        }
        return ancestors
    }
}
