public import Foundation

/// The replay file of a classic terminal's scrollback (`CMUX_RESTORE_SCROLLBACK_FILE`).
public struct ClassicScrollbackReplay {
    public init() {}
    /// Writes `text` to a new file only this user can read, in a folder only this user can open,
    /// under `directory` (the user's temporary folder).
    nonisolated public static func write(_ text: String, in directory: URL? = nil) throws -> URL {
        let directory = directory ?? FileManager.default.temporaryDirectory
        let folder = directory.appendingPathComponent("cmux-next-scrollback", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: false)
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return file
    }
}
