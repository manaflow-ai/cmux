import CmuxNextCloud
public import Foundation
import LocalAuthentication
import Security

/// The real file system.
public struct LiveFileReader: FileReading {
    public init() {}
    public func data(at url: URL) -> Data? { try? Data(contentsOf: url) }
    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Keychain presence by attributes only: `kSecReturnAttributes` without
/// `kSecReturnData` never decrypts the item, so macOS shows no prompt and
/// cmux never holds the other app's secret.
public struct SystemKeychainProbe: KeychainProbing {
    public init() {}

    public func hasGenericPassword(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: NoPromptContext.make(),
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Interaction-not-allowed still proves the item exists.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}

/// A local model server answers an HTTP GET within the deadline. Loopback
/// only; no credentials are sent.
public struct HTTPServerProbe: LocalServerProbing {
    let session: URLSession
    let timeout: Duration

    public init(session: URLSession = .shared, timeout: Duration = .milliseconds(800)) {
        self.session = session
        self.timeout = timeout
    }

    public func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.components.seconds) + 1)
        request.httpMethod = "GET"
        let session = session, prepared = request
        do {
            let (_, response) = try await withDeadline(timeout, label: "probe \(url.host ?? "")") {
                try await session.data(for: prepared)
            }
            return (response as? HTTPURLResponse).map { (200..<500).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }
}
