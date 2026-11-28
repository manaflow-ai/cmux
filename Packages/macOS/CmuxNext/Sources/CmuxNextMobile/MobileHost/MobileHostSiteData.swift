public import Foundation

/// A Rust-authorized Open on iPhone request. Rust owns site and peer policy.
public struct MobileHostSiteDataRequest: Sendable, Equatable {
    public let request: UInt64
    public let surface: UInt64
    public let site: String
    public let url: String

    public init(request: UInt64, surface: UInt64, site: String, url: String) {
        self.request = request
        self.surface = surface
        self.site = site
        self.url = url
    }
}

/// An engine snapshot, carried only over hostd's private stdin. Never retained or logged.
/// Rust filters the snapshot and caps expiry before sending it to the paired phone.
public struct MobileHostSiteData: Encodable, Sendable, CustomStringConvertible {
    public struct Cookie: Encodable, Sendable, CustomStringConvertible {
        public let name: String
        public let value: String
        public let domain: String
        public let path: String
        public let expiresMS: Int64?
        public let secure: Bool
        public let httpOnly: Bool
        public let sameSite: String?

        public init(name: String, value: String, domain: String, path: String, expiresMS: Int64?,
                    secure: Bool, httpOnly: Bool, sameSite: String?) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.expiresMS = expiresMS
            self.secure = secure
            self.httpOnly = httpOnly
            self.sameSite = sameSite
        }

        enum CodingKeys: String, CodingKey {
            case name, value, domain, path, secure
            case expiresMS = "expires_ms", httpOnly = "http_only", sameSite = "same_site"
        }

        public var description: String { "MobileHostSiteData.Cookie(<redacted>)" }
    }

    public struct StorageArea: Encodable, Sendable, CustomStringConvertible {
        public let origin: String
        public let items: [[String]]

        public init(origin: String, items: [[String]]) {
            self.origin = origin
            self.items = items
        }

        public var description: String { "MobileHostSiteData.StorageArea(<redacted>)" }
    }

    public let profileID: String
    public let agentsProfile: Bool
    public let incognito: Bool
    public let cookies: [Cookie]
    public let localStorage: [StorageArea]

    public init(profileID: String, agentsProfile: Bool, incognito: Bool, cookies: [Cookie], localStorage: [StorageArea]) {
        self.profileID = profileID
        self.agentsProfile = agentsProfile
        self.incognito = incognito
        self.cookies = cookies
        self.localStorage = localStorage
    }

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id", agentsProfile = "agents_profile", incognito, cookies
        case localStorage = "local_storage"
    }

    public var description: String { "MobileHostSiteData(<redacted>)" }
}

extension MobileHostLaunch {
    public static func siteDataHandoffLine(enabled: Bool) -> Data {
        anyLine(["type": "site_data_handoff", "enabled": enabled])
    }

    public static func siteDataFailedLine(request: UInt64) -> Data {
        // Engine errors can contain page data. Keep the failure constant and never log them.
        anyLine(["type": "site_data_failed", "request": request, "reason": "site data unavailable"])
    }

    public static func siteDataLine(request: UInt64, data: MobileHostSiteData) -> Data? {
        struct Reply: Encodable {
            let type = "site_data"
            let request: UInt64
            let data: MobileHostSiteData
        }
        guard var line = try? JSONEncoder().encode(Reply(request: request, data: data)),
              line.count <= 2 * 1024 * 1024 else { return nil }
        line.append(0x0a)
        return line
    }
}
