public import CmuxInstallAuthCore
import CryptoKit
public import Foundation

/// Where the Mac app keeps its install keys and records (cx-wb5.64), one
/// key per Stack user (two users on one Mac never share or rotate each
/// other's key).
/// - ``files(directory:)``: a debug build without a Team ID: software P-256
///   keys and the records in 0600 files in a 0700 directory, so a rebuild
///   never raises a Keychain prompt (the same known DEV gap as the P8
///   frontend key, identity.md).
/// - ``enclave(service:directory:)``: every other build: keys in the Secure
///   Enclave (only the encrypted blob is stored, in the Keychain); records
///   (user and install ids, not secrets) in the 0600 file.
public struct MacInstallStore: Sendable {
    private let makeSigner: @Sendable (String) -> any InstallSigner
    private let records: URL
    /// Whether keys live in the Secure Enclave.
    public let usesSecureEnclave: Bool

    public static func files(directory: URL) -> MacInstallStore {
        MacInstallStore(makeSigner: { account in FileInstallSigner(file: directory.appendingPathComponent(account)) },
                        records: directory.appendingPathComponent("install-records.json"), usesSecureEnclave: false)
    }

    public static func enclave(service: String, directory: URL) -> MacInstallStore {
        MacInstallStore(makeSigner: { account in EnclaveInstallSigner(service: service, account: account) },
                        records: directory.appendingPathComponent("install-records.json"), usesSecureEnclave: true)
    }

    /// The store for this process. Only a debug build with no Team ID uses
    /// files; a release build, or a build whose Team ID could not be read,
    /// uses the Secure Enclave (fails closed).
    public static func forApp(directory: URL, service: String, team: String?, isDebugBuild: Bool) -> MacInstallStore {
        isDebugBuild && team == nil ? .files(directory: directory) : .enclave(service: service, directory: directory)
    }

    /// The key of `user`: `install-key-<first 16 hex of SHA-256(user)>`.
    func signer(for user: String) -> any InstallSigner {
        let digest = SHA256.hash(data: Data(user.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return makeSigner("install-key-\(digest)")
    }

    func record(for user: String) -> InstallRecord? {
        guard let data = try? Data(contentsOf: records),
              let all = try? JSONDecoder().decode([String: InstallRecord].self, from: data) else { return nil }
        return all[user]
    }

    func saveRecord(_ record: InstallRecord?, for user: String) {
        var all = (try? Data(contentsOf: records)).flatMap { try? JSONDecoder().decode([String: InstallRecord].self, from: $0) } ?? [:]
        all[user] = record
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? OwnerOnlyFile.write(data, to: records)
    }
}

/// 0600 files in a 0700 directory: written to a unique temporary file
/// (created exclusively, never through a symlink), synced, then renamed.
enum OwnerOnlyFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = data.withUnsafeBytes { buffer in buffer.baseAddress.map { Darwin.write(fd, $0, buffer.count) } ?? 0 }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
