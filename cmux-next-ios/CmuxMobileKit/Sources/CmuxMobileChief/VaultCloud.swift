import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The cmux vault's person routes (`/v1/cloud/vault`, cmuxterm-hq docs/design/e2e-vault.md) as the
/// signed-in account: the same bearer, refresh and build space as this account's other Cloud calls.
/// Every body is sealed bytes, names and scopes; a value never travels in the clear.
extension AccountCloud {
    /// One answer of the vault routes: its status and its body, as they came.
    public struct VaultReply: Sendable {
        public var status: Int
        public var body: Data
    }

    /// The only paths ``vault(_:_:device:body:timeout:)`` sends.
    static let vaultRoot = "/v1/cloud/vault"
    static let vaultDeviceHeader = "x-cmux-vault-device"

    /// Whether `path` is one of the vault routes (no `..` part, plain or percent-encoded).
    static func isVaultPath(_ path: String) -> Bool {
        let root = vaultRoot
        guard path == root || path.hasPrefix(root + "/") || path.hasPrefix(root + "?"),
              let plain = path.removingPercentEncoding else { return false }
        return !plain.contains("..")
    }

    /// A vault device id as the header may carry it (`dev_` and base64url).
    static func isVaultDevice(_ id: String) -> Bool {
        id.hasPrefix("dev_") && id.count <= 64 && id.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-"
        }
    }

    /// `method path` to the vault routes, naming this phone's vault device. A path outside them is
    /// refused here and never sent: the Rust client reaches no other route with this account's bearer.
    public func vault(_ method: String, _ path: String, device: String?, body: Data?, timeout: TimeInterval) async throws -> VaultReply {
        guard ["GET", "POST", "PUT", "DELETE"].contains(method), Self.isVaultPath(path),
              device.map(Self.isVaultDevice) ?? true else { throw Failure.badReply }
        do {
            var forceRefresh = false
            while true {
                let token = try await http.accessToken(forceRefresh)
                var request = try http.makeRequest(method, path, token: token, body: body, timeout: timeout)
                if let device { request.setValue(device, forHTTPHeaderField: Self.vaultDeviceHeader) }
                let (data, response) = try await http.session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401, !forceRefresh {
                    forceRefresh = true
                    continue
                }
                return VaultReply(status: status, body: data)
            }
        } catch {
            throw Self.cancellation(error) ?? Failure.unreachable
        }
    }
}

extension ChiefSources {
    /// The Keychain account this phone's vault device key is kept under: one per person, Cloud
    /// service and build space, so another account or a dev build never reads it.
    public var vaultKeyAccount: String? {
        personalListIdentity.map { $0.joined(separator: "|") }
    }

    /// The label the person's other devices see for this phone.
    public static var vaultDeviceLabel: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "iPhone"
        #endif
    }
}
