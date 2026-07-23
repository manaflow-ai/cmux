import Foundation

/// Persists last-writer ownership across every cmux process on the Mac.
/// Atomic replacement lets a newer pane supersede an older route or camera
/// cleanup without keeping a long-lived advisory lock.
struct SimulatorCrossProcessOwnershipStore: Sendable {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager().temporaryDirectory
            .appendingPathComponent("com.cmux.simulator-ownership", isDirectory: true)
    }

    func claim(namespace: String, components: [String]) throws -> UUID {
        let token = UUID()
        try FileManager().createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(token.uuidString.utf8).write(
            to: fileURL(namespace: namespace, components: components),
            options: .atomic
        )
        return token
    }

    func isCurrent(_ token: UUID, namespace: String, components: [String]) -> Bool {
        guard let data = try? Data(contentsOf: fileURL(namespace: namespace, components: components)),
              let value = String(data: data, encoding: .utf8) else { return false }
        return value == token.uuidString
    }

    private func fileURL(namespace: String, components: [String]) -> URL {
        directory.appendingPathComponent(hash([namespace] + components) + ".owner")
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
