import Foundation

// SAFETY: FileManager's operations are thread-safe when no delegate is set;
// this value never exposes or configures a delegate on its private instance.
struct SimulatorCameraFileSystem: @unchecked Sendable {
    private let manager: FileManager

    init(manager: FileManager = FileManager()) {
        self.manager = manager
    }

    func fileExists(atPath path: String) -> Bool { manager.fileExists(atPath: path) }
    func contents(atPath path: String) -> Data? { manager.contents(atPath: path) }
    func isReadableFile(atPath path: String) -> Bool { manager.isReadableFile(atPath: path) }

    func cachesDirectory() throws -> URL {
        try manager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    func createDirectory(at url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws { try manager.removeItem(at: url) }
    func moveItem(at source: URL, to destination: URL) throws {
        try manager.moveItem(at: source, to: destination)
    }
}
