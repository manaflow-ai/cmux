import Foundation

enum BrowserLocalFileReadAccessPolicy: String, Codable, Equatable, Hashable, Sendable {
    case containingDirectory
    case fileOnly
}
