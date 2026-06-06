import Foundation

struct OpenCodeEventStreamParser {
    private var dataLines: [String] = []

    mutating func consumeLine(_ line: String) -> [[String: Any]] {
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !line.isEmpty else {
            return flush()
        }
        guard line.hasPrefix("data:") else {
            return []
        }

        var data = String(line.dropFirst("data:".count))
        if data.hasPrefix(" ") {
            data.removeFirst()
        }
        dataLines.append(data)
        return []
    }

    mutating func flush() -> [[String: Any]] {
        guard !dataLines.isEmpty else { return [] }
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return []
        }
        return [object]
    }
}

