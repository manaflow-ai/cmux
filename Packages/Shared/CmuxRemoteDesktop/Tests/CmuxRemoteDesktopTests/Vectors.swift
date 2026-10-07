import CmuxMobileWire
import Foundation

/// `schemas/remote-desktop/desktop.json`, the file the Rust desktop module replays.
struct Vectors {
    static let file: JSONValue = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url = url.deletingLastPathComponent() }
        let data = (try? Data(contentsOf: url.appendingPathComponent("schemas/remote-desktop/desktop.json"))) ?? Data()
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }()

    static func list(_ key: String) -> [JSONValue] {
        guard case .array(let values)? = file[key] else { return [] }
        return values
    }

    /// Integral doubles and ints compare equal (JSON has one number type).
    static func normalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case .double(let d) where d.rounded() == d && abs(d) < 1e15: .int(Int64(d))
        case .array(let a): .array(a.map(normalized))
        case .object(let o): .object(o.mapValues(normalized))
        default: value
        }
    }
}
