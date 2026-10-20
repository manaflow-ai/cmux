import Foundation

/// Persists the live computer-use authority consumed by per-surface agent shims.
actor ComputerUseLiveSettingRepository {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(enabled ? "1\n".utf8 : "0\n".utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // The spawn-time environment remains the safe fallback when this
            // best-effort live authority cannot be persisted.
        }
    }
}
