public import Foundation

/// Tiny atomic JSON-on-disk cache for credentials, policies, verification
/// keys, and grants. Steady-state independence (dialing with the backend
/// down) is only real if this survives relaunches.
public struct IrxDiskCache<Value: Codable & Sendable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
