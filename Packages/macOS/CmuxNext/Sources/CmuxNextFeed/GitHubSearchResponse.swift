public import Foundation

nonisolated struct GitHubSearchResponse<Entry: Decodable>: Decodable {
    var items: [Entry]
}
