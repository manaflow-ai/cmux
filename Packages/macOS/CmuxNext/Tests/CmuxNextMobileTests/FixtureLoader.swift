import Foundation

/// Reads a captured daemon fixture (see scripts/cmux-next/capture-mobile-render-fixtures.py).
enum FixtureLoader {
    static func object(_ name: String) throws -> [String: Any] {
        let url = try require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func data(_ name: String, key: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: try require(object(name)[key]))
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw FixtureError.missing }
    return value
}

enum FixtureError: Error { case missing }
