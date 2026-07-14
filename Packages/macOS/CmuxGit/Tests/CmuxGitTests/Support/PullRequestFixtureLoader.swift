import Foundation
import Testing

struct PullRequestFixtureLoader {
    func decode<Value: Decodable>(_ type: Value.Type, named name: String) throws -> Value {
        let data = try data(named: name)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    func data(named name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
