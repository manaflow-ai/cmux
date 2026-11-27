import Foundation

/// `cef_content_setting_values_t`.
nonisolated enum CEFContentSetting: Int32, Sendable, Equatable {
    case `default` = 0
    case allow = 1
    case block = 2
    case ask = 3
    case sessionOnly = 4
    case detectImportantContent = 5

    init(_ setting: SitePermissionSetting) {
        switch setting {
        case .allow: self = .allow
        case .block: self = .block
        case .ask: self = .ask
        }
    }

    /// As a Page Info setting; `sessionOnly` (cookies) counts as allowed,
    /// `detectImportantContent` (legacy plugins) as ask.
    var siteSetting: SitePermissionSetting? {
        switch self {
        case .allow, .sessionOnly: .allow
        case .block: .block
        case .ask, .detectImportantContent: .ask
        case .default: nil
        }
    }
}

/// One cookie as `cmux_shim_visit_cookies` reports it.
nonisolated struct CEFCookie: Sendable, Hashable {
    var name: String
    var domain: String
    var path: String

    /// The host the cookie belongs to, without a domain cookie's leading dot.
    var host: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }

    /// Whether the cookie is sent to `host` (RFC 6265 domain match).
    func matches(host candidate: String) -> Bool {
        let candidate = candidate.lowercased()
        let own = host.lowercased()
        if candidate == own { return true }
        return domain.hasPrefix(".") && candidate.hasSuffix("." + own)
    }

    static func parse(_ json: String) -> [CEFCookie] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String, let domain = entry["domain"] as? String else { return nil }
            return CEFCookie(name: name, domain: domain, path: entry["path"] as? String ?? "/")
        }
    }
}

/// `cmux_shim_ssl_status` of the visible navigation entry.
nonisolated struct CEFSSLStatus: Sendable, Equatable {
    var isSecure: Bool
    /// `cef_cert_status_t` bits.
    var certStatus: Int
    /// `cef_ssl_content_status_t` bits (mixed content).
    var contentStatus: Int
    var url: String
    /// DER certificates, leaf first.
    var chain: [Data]

    /// `CERT_STATUS_ALL_ERRORS`: the bits below `CERT_STATUS_IS_EV` that
    /// are errors (revocation checks unavailable are not).
    static let errorMask = 0xFFFF & ~(1 << 4 | 1 << 5)

    var hasCertificateError: Bool { certStatus & Self.errorMask != 0 }
    /// Displayed or ran insecure content (`SSL_CONTENT_*_INSECURE_CONTENT`).
    var hasMixedContent: Bool { contentStatus & (1 << 0 | 1 << 1) != 0 }

    static func parse(_ json: String) -> CEFSSLStatus? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let chain = (object["chain"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
        return CEFSSLStatus(
            isSecure: object["secure"] as? Bool ?? false,
            certStatus: object["certStatus"] as? Int ?? 0,
            contentStatus: object["contentStatus"] as? Int ?? 0,
            url: object["url"] as? String ?? "",
            chain: chain
        )
    }
}
