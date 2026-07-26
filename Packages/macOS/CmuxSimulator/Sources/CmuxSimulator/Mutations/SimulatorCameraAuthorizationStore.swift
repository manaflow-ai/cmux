import Foundation

/// Persists the authorization that camera injection temporarily replaces.
///
/// Worker crashes cannot erase this record, so the host's durable Simulator
/// cleanup can restore the prior TCC state after relaunching the target app.
public struct SimulatorCameraAuthorizationStore: Sendable {
    private struct Record: Codable {
        let deviceIdentifier: String
        let bundleIdentifier: String
        let authorization: SimulatorPrivacyAuthorization
    }

    private let directory: URL

    /// Creates a store in the shared Simulator ownership directory by default.
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager().temporaryDirectory
            .appendingPathComponent("com.cmux.simulator-ownership", isDirectory: true)
            .appendingPathComponent("camera-authorizations", isDirectory: true)
    }

    package func save(
        _ authorization: SimulatorPrivacyAuthorization,
        deviceIdentifier: String,
        bundleIdentifier: String
    ) throws {
        guard [.notDetermined, .denied, .granted].contains(authorization) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if try self.authorization(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        ) != nil {
            return
        }
        let fileManager = FileManager()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(Record(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier,
            authorization: authorization
        ))
        let url = fileURL(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    package func authorization(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) throws -> SimulatorPrivacyAuthorization? {
        let url = fileURL(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        guard FileManager().fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.deviceIdentifier == deviceIdentifier,
              record.bundleIdentifier == bundleIdentifier,
              [.notDetermined, .denied, .granted].contains(record.authorization)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record.authorization
    }

    package func remove(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) throws {
        let url = fileURL(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        guard FileManager().fileExists(atPath: url.path) else { return }
        _ = try authorization(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        try FileManager().removeItem(at: url)
    }

    private func fileURL(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) -> URL {
        directory.appendingPathComponent(
            hash([deviceIdentifier, bundleIdentifier]) + ".json"
        )
    }

    private func hash(_ values: [String]) -> String {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b97f4a7c15
        for byte in values.joined(separator: "\0").utf8 {
            first ^= UInt64(byte)
            first &*= 0x100000001b3
            second ^= UInt64(byte) &+ 0x9d
            second = (second << 7) | (second >> 57)
            second &*= 0x9e3779b185ebca87
        }
        return String(format: "%016llx%016llx", first, second)
    }
}
