import Foundation

struct DockConfigLocation: Hashable, Sendable {
    let origin: DockConfigOrigin
    let path: String

    var canonicalIdentifier: String {
        switch origin {
        case .local: path
        case .remote: "\(origin.identity):\(path)"
        }
    }

    var displayPath: String { origin.displayPath(path) }

    var localURL: URL? {
        guard origin == .local else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false)
    }
}
