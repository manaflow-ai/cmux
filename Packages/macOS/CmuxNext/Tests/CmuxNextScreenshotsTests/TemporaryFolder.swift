import Foundation

/// A fresh folder for one test, removed when the value is dropped. Its URL is the kernel's name for
/// it (`realpath`: /private/var/..., as FSEvents reports paths).
///
/// It lives one level below a shared `cmux-screenshots-tests` folder, never directly in `$TMPDIR`:
/// macOS guards `$TMPDIR/<entry>/TemporaryItems` (a sandboxed app's temporary-items folder), so the
/// `TemporaryItems` folder the source detector tests make there could not be listed or removed (on
/// a CI mini the call blocked, then failed). Every such test left its folder behind: hundreds per
/// mini, and a disk sweep that walked one stalled. One level deeper the name is not guarded.
///
/// On a GitHub Actions runner the shared folder is in `$RUNNER_TEMP`, which the runner empties after
/// each job, so a test process killed before `deinit` (a timeout, a crash) leaves nothing either.
nonisolated final class TemporaryFolder: Sendable {
    /// The shared parent: `$RUNNER_TEMP/cmux-screenshots-tests` on a runner, else under `$TMPDIR`.
    static func root(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["RUNNER_TEMP"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("cmux-screenshots-tests", isDirectory: true)
    }

    let url: URL

    init() throws {
        let base = Self.root().appendingPathComponent(UUID().uuidString, isDirectory: true)
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
