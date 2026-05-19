import CMUXVNC
import Foundation
import Security

enum VNCKeychainCredentialProvider {
    static func password(for session: MacfleetVNCSession) -> String? {
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
