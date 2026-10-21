import Foundation

/// A fresh folder under the test's temporary directory, removed when the value is dropped. Its
/// URL is the kernel's name for it (`realpath`: /private/var/..., as FSEvents reports paths).
nonisolated final class TemporaryFolder: Sendable {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-screenshots-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let real = base.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        url = URL(fileURLWithPath: real ?? base.path, isDirectory: true)
    }

    @discardableResult
    func write(_ relative: String, bytes: Int = 4, modified: Date? = nil) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let folder = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
