import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Socket password resolution
enum SocketPasswordResolver {
    private static let service = "com.cmuxterm.app.socket-control"
    private static let account = "local-socket-password"

    static func resolve(explicit: String?, socketPath: String) -> String? {
        if let explicit = normalized(explicit) {
            return explicit
        }
        if let env = normalized(ProcessInfo.processInfo.environment["CMUX_SOCKET_PASSWORD"]) {
            return env
        }
        if let filePassword = loadFromFile() {
            return filePassword
        }
        return loadFromKeychain(socketPath: socketPath)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadFromFile() -> String? {
        // Resolve through the shared store so the CLI reads the exact path the app
        // writes — the non-TCC cmux state directory, not Application Support
        // (https://github.com/manaflow-ai/cmux/issues/5146). The CLI is a
        // composition root, so it names the concrete `FileManager.default` here.
        guard let passwordURL = SocketControlPasswordStore.defaultPasswordFileURL(fileManager: .default) else {
            return nil
        }
        guard let data = try? Data(contentsOf: passwordURL) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(value)
    }

    private static func keychainServices(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let scope = keychainScope(socketPath: socketPath, environment: environment) else {
            return [service]
        }
        return ["\(service).\(scope)", service]
    }

    private static func keychainScope(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let tag = normalized(environment["CMUX_TAG"]) {
            let scoped = sanitizeScope(tag)
            if !scoped.isEmpty {
                return scoped
            }
        }

        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["cmux-debug-", "cmux-"]
        for prefix in prefixes {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".sock") else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -".sock".count)
            guard start < end else { continue }
            let rawScope = String(candidate[start..<end])
            let scoped = sanitizeScope(rawScope)
            if !scoped.isEmpty {
                return scoped
            }
        }
        return nil
    }

    private static func sanitizeScope(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let mappedScalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "."
        }
        var normalizedScope = String(mappedScalars)
        normalizedScope = normalizedScope.replacingOccurrences(
            of: "\\.+",
            with: ".",
            options: .regularExpression
        )
        normalizedScope = normalizedScope.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedScope
    }

    private static func loadFromKeychain(socketPath: String) -> String? {
        for service in keychainServices(socketPath: socketPath) {
            let authContext = LAContext()
            authContext.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                // Never trigger keychain UI from CLI commands; fail fast instead.
                kSecUseAuthenticationContext as String: authContext,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                continue
            }
            guard status == errSecSuccess else {
                continue
            }
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                continue
            }
            return password
        }
        return nil
    }
}

