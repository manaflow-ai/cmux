public import CmuxInstallAuthCore
import CryptoKit
public import Foundation

/// `host.enroll {name, platform}` as the Mac's install (TeamDO, the existing
/// host registration path). The owner keys the host by the enrolling
/// install, so a repeat returns the same `host_…` id (a lookup) and a new
/// name renames it.
public struct HostEnrollment: Sendable {
    public enum Failure: Error, Hashable {
        case refused(code: String, message: String)
        case malformedReply
    }

    private let transport: any InstallAuthTransport
    private let clientVersion: String?

    public init(transport: any InstallAuthTransport, clientVersion: String?) {
        self.transport = transport
        self.clientVersion = clientVersion
    }

    /// The host id this install enrolled, enrolling it on first use.
    public func enroll(install: String, name: String, token: String) async throws -> String {
        let label = InstallAuthClientName.clamp(name, fallback: "Mac")
        // One key per (install, name): a lost reply replays, a rename is a new intent.
        let digest = SHA256.hash(data: Data(label.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let body = try JSONSerialization.data(withJSONObject: [
            "op": "host.enroll", "params": ["name": label, "platform": "macos"],
            "idempotency_key": "host-enroll-\(install)-\(digest)", "origin": "cli",
        ] as [String: Any], options: [.sortedKeys])
        let (status, data) = try await transport.post("/v1/ops", json: body, bearer: token,
                                                      headers: InstallAuthClient.headers(clientVersion: clientVersion))
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.malformedReply }
        guard (200..<300).contains(status), reply["ok"] as? Bool == true else {
            let error = reply["error"] as? [String: Any]
            throw Failure.refused(code: error?["code"] as? String ?? reply["code"] as? String ?? "http_\(status)",
                                  message: error?["message"] as? String ?? "")
        }
        guard let host = (reply["value"] as? [String: Any])?["id"] as? String, host.hasPrefix("host_") else {
            throw Failure.malformedReply
        }
        return host
    }
}

/// The owner's display-name rule (1 to 80 UTF-16 units).
enum InstallAuthClientName {
    static func clamp(_ name: String, fallback: String) -> String {
        var result = ""
        for character in name.trimmingCharacters(in: .whitespacesAndNewlines) {
            if result.utf16.count + String(character).utf16.count > 80 { break }
            result.append(character)
        }
        return result.isEmpty ? fallback : result
    }
}
