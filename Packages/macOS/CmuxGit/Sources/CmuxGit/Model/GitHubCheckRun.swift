import Foundation

struct GitHubCheckRun: Decodable, Sendable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let detailsURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case conclusion
        case detailsURL = "details_url"
    }
}
