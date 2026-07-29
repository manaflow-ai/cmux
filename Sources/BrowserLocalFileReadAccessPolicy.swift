import Foundation

enum BrowserLocalFileReadAccessPolicy: String, Codable, Equatable, Sendable {
    case containingDirectory
    case fileOnly
}
