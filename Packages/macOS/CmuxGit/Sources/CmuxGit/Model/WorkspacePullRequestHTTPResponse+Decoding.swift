import Foundation

extension WorkspacePullRequestHTTPResponse {
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
