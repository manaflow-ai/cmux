public import CmuxInstallAuthCore
import CryptoKit
public import Foundation
import Security

/// Where the Mac app keeps its install key and records (cx-wb5.64).
/// - ``files(directory:)``: a development build (unsigned or ad-hoc, no Team
///   ID): a software P-256 key and the records in 0600 files in a 0700
///   directory, so a rebuild never raises a Keychain prompt (the same known
///   DEV gap as the P8 frontend key, identity.md).
/// - ``enclave(service:directory:)``: a signed build: the key in the Secure
///   Enclave (only its encrypted blob is stored, in the Keychain); records
///   (user and install ids, not secrets) in the 0600 file.
public struct MacInstallStore: Sendable {
    public let signer: any InstallSigner
    private let records: URL

    public static func files(directory: URL) -> MacInstallStore {
        MacInstallStore(signer: FileInstallSigner(file: directory.appendingPathComponent("install-key")),
                        records: directory.appendingPathComponent("install-records.json"))
    }

    public static func enclave(service: String, directory: URL) -> MacInstallStore {
        MacInstallStore(signer: EnclaveInstallSigner(service: service),
                        records: directory.appendingPathComponent("install-records.json"))
    }

    /// The store for this process: Secure Enclave when signed with a Team ID.
    public static func forApp(directory: URL, service: String, team: String?) -> MacInstallStore {
        team == nil ? .files(directory: directory) : .enclave(service: service, directory: directory)
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

/// 0600 files in a 0700 directory, replaced atomically.
enum OwnerOnlyFile {
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
