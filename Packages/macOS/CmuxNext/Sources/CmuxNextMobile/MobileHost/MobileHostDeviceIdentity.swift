public import Foundation

/// This Mac's persistent mobile device id: a UUID in `<directory>/device-id`
/// (the app's Application Support folder, per bundle id), created on first
/// use with mode 0600. The id is not a secret; the service ties it to the
/// signed-in user at registration.
public struct MobileHostDeviceIdentity: Sendable {
    public let directory: URL
    private let fileManager: @Sendable () -> FileManager

    public init(directory: URL, fileManager: @escaping @Sendable () -> FileManager = { .default }) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public var file: URL { directory.appendingPathComponent("device-id", isDirectory: false) }

    /// The stored id, or a new one written now. Throws when the folder cannot be written.
    public func deviceID() throws -> String {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id.uuidString.lowercased()
        }
        let id = UUID().uuidString.lowercased()
        try fileManager().createDirectory(at: directory, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
        try Data(id.utf8).write(to: file, options: .atomic)
        try fileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return id
    }

    /// Forgets the stored id (the owner removed this Mac): the next ``deviceID()`` is new.
    public func forget() {
        try? fileManager().removeItem(at: file)
    }
}
