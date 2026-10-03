public import Foundation

struct GitHubSearchResponse<Entry: Decodable>: Decodable {
    var items: [Entry]
}
