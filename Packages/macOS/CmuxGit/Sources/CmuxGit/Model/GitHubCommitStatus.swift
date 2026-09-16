import Foundation

struct GitHubCommitStatus: Decodable, Sendable {
    let id: Int
    let context: String
    let state: String
    let targetURL: String?

    enum CodingKeys: String, CodingKey {
        case id, context, state
        case targetURL = "target_url"
    }
}
