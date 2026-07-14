import Foundation
import Testing

struct PullRequestFixtureLoader {
    func decode<Value: Decodable>(_ type: Value.Type, named name: String) throws -> Value {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
