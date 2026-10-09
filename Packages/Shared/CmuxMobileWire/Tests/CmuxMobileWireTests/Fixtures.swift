import Foundation
@testable import CmuxMobileWire

/// Reads schemas/mobile-rpc (the contract shared with the TS codec).
struct Fixtures {
    let root: URL

    init() {
        root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schemas/mobile-rpc")
    }

    func data(_ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    func json(_ path: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data(path))
    }

    /// Family fixture files (everything in fixtures/ but frames.json and binary.json).
    func familyFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("fixtures").path)
            .filter { $0.hasSuffix(".json") && $0 != "frames.json" && $0 != "binary.json" }
            .sorted()
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension JSONValue {
    var intValue: Int? {
        if case .int(let v) = self { return Int(v) }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}
