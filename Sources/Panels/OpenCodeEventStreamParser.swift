import Foundation

struct OpenCodeEventStreamParser {
    private static let maxEventDataBytes = 1024 * 1024

    private var dataLines: [String] = []
    private var dataByteCount = 0

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
        let separatorBytes = dataLines.isEmpty ? 0 : 1
        dataByteCount += data.utf8.count + separatorBytes
        guard dataByteCount <= Self.maxEventDataBytes else {
            reset()
            return []
        }
        dataLines.append(data)
        return []
    }

    mutating func flush() -> [[String: Any]] {
        guard !dataLines.isEmpty else { return [] }
        let data = dataLines.joined(separator: "\n")
        reset()
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return []
        }
        return [object]
    }

    private mutating func reset() {
        dataLines.removeAll(keepingCapacity: true)
        dataByteCount = 0
    }
}
