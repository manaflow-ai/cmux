import CMUXVNC
import Foundation
import Security

enum VNCKeychainCredentialProvider {
    struct InternetPasswordLookup: Equatable {
        let server: String
        let account: String
        let port: Int
    }

    static func password(for session: MacfleetVNCSession) -> String? {
        for lookup in internetPasswordLookups(for: session) {
            if let password = internetPassword(server: lookup.server, account: lookup.account, port: lookup.port) {
                return password
            }
        }

        let candidates: [(service: String, account: String)] = [
            ("Screen Sharing", "\(session.address) (\(session.username))"),
            ("Screen Sharing", "\(session.name) (\(session.username))"),
            ("Screen Sharing", session.address),
            ("Screen Sharing", session.name),
            ("cmux-vnc", session.name),
            ("cmux-vnc", session.address)
        ]

        for candidate in candidates {
            if let password = genericPassword(service: candidate.service, account: candidate.account) {
                return password
            }
        }

        return nil
    }

    static func internetPasswordLookups(for session: MacfleetVNCSession) -> [InternetPasswordLookup] {
        let servers = uniqueNonEmpty([
            session.address,
            session.name,
            "\(session.address):\(session.port)",
            "\(session.name):\(session.port)",
        ])
        let accounts = uniqueNonEmpty([session.username, session.address, session.name])
        return servers.flatMap { server in
            accounts.map { account in
                InternetPasswordLookup(server: server, account: account, port: session.port)
            }
        }
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func internetPassword(server: String, account: String, port: Int) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecAttrPort as String: port
        ]
        return password(query: query)
    }

    private static func genericPassword(service: String, account: String) -> String? {
        password(query: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ])
    }

    private static func password(query baseQuery: [String: Any]) -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            return nil
        }
        return password
    }
}
