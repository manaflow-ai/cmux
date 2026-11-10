import Foundation
import Security

/// A value and its authorization travel in one Keychain payload, under the app's access list.
/// The filesystem index is writable by agents and cannot authorize a release or a scope change.
nonisolated struct CredentialVaultSecretRecord: Codable, Equatable, Sendable {
    private var version = 1
    var value: String
    var scope: [CredentialVault.Consumer]

    init(value: String, scope: [CredentialVault.Consumer]) {
        self.value = value
        self.scope = CredentialVault.Consumer.allCases.filter(scope.contains)
    }

    /// 0xFF cannot begin an old UTF-8 value, even one that happens to be a JSON record.
    private static let marker = Data([0xFF, 0x43, 0x4D, 0x55, 0x58, 0x56, 0x31, 0x00])

    init(data: Data) throws {
        if data.starts(with: Self.marker) {
            do {
                let record = try JSONDecoder().decode(Self.self, from: Data(data.dropFirst(Self.marker.count)))
                guard record.version == 1, !record.scope.isEmpty else { throw CredentialVault.Failure.keychain(errSecDecode) }
                self = record
            } catch {
                throw CredentialVault.Failure.keychain(errSecDecode)
            }
        } else {
            guard let value = String(data: data, encoding: .utf8) else { throw CredentialVault.Failure.keychain(errSecDecode) }
            // Legacy values had no protected scope. Never grant agents the index's claimed scope.
            self.init(value: value, scope: [.user])
        }
    }

    func encoded() throws -> Data {
        var data = Self.marker
        data.append(try JSONEncoder().encode(self))
        return data
    }
}
