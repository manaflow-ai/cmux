import Foundation

struct JSONLineDecoder {
    init() {
    }

    func decode(_ line: String) -> JSONValue? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
