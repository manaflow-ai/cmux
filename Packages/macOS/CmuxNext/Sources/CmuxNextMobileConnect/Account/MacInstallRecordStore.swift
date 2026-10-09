public import CmuxInstallAuthCore
public import Foundation

/// The Mac's (Stack user -> backend user and install) records, one JSON file
/// next to the install key. Identifiers only, no secret: a record without the
/// key cannot mint a token.
public struct MacInstallRecordStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func record(for stackUser: String) -> InstallRecord? {
        all()[stackUser]
    }

    public func setRecord(_ record: InstallRecord?, for stackUser: String) {
        var records = all()
        records[stackUser] = record
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func all() -> [String: InstallRecord] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: InstallRecord].self, from: data)) ?? [:]
    }
}
