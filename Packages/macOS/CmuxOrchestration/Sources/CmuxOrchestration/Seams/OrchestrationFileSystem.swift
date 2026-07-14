public import Foundation

/// Filesystem seam so the store and validator are unit-testable with an
/// in-memory fake (the same seam-protocol shape CmuxControlSocket uses).
public protocol OrchestrationFileSystem: Sendable {
    func fileExists(atPath path: String) -> Bool
    func directoryExists(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
    /// Whether the path itself is a symbolic link (not resolved).
    func isSymbolicLink(atPath path: String) -> Bool
    func contentsOfDirectory(atPath path: String) throws -> [String]
    func readData(atPath path: String) throws -> Data
    func writeData(_ data: Data, atPath path: String) throws
    func createDirectory(atPath path: String) throws
    func removeItem(atPath path: String) throws
    func copyItem(atPath source: String, toPath destination: String) throws
}

/// FileManager-backed default implementation.
public struct DefaultOrchestrationFileSystem: OrchestrationFileSystem {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    public func isSymbolicLink(atPath path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    public func contentsOfDirectory(atPath path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    public func readData(atPath path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func writeData(_ data: Data, atPath path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func createDirectory(atPath path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
    }

    public func removeItem(atPath path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    public func copyItem(atPath source: String, toPath destination: String) throws {
        try FileManager.default.copyItem(atPath: source, toPath: destination)
    }
}
