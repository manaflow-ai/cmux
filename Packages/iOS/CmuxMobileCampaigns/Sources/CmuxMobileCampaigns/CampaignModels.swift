public import Foundation

/// A server-authored in-app message from `/api/campaigns`.
///
/// Decoding is deliberately forward-compatible: a campaign this build cannot
/// fully render (unknown template, reshow policy, or button action) throws
/// during element decoding and is dropped by ``CampaignCatalog``'s lossy array,
/// never failing the whole catalog. New capabilities ship server-side without
/// breaking older apps.
public struct Campaign: Sendable, Equatable, Identifiable, Decodable {
    public enum Template: String, Sendable, Decodable {
        case banner
        case sheet
        case fullscreen
    }

    public enum ReshowPolicy: String, Sendable, Decodable {
        /// Present at most once ever, however it was closed.
        case once
        /// Present at most once per app marketing version.
        case oncePerVersion
        /// Present on every opportunity until explicitly dismissed.
        case untilDismissed
    }

    public let id: String
    public let template: Template
    /// Raw platform strings; unknown platforms are ignored at eligibility time.
    public let platforms: [String]
    public let minAppVersion: CampaignAppVersion?
    public let maxAppVersion: CampaignAppVersion?
    public let startsAt: Date?
    public let endsAt: Date?
    /// 0-100; campaigns omit it for a full rollout.
    public let rolloutPercent: Double
    public let priority: Int
    public let reshowPolicy: ReshowPolicy
    public let showInWhatsNew: Bool
    public let title: CampaignText
    public let body: CampaignText
    public let image: CampaignImage?
    /// "#RRGGBB", already validated server-side.
    public let accentColor: String?
    public let buttons: [CampaignButton]

    enum CodingKeys: String, CodingKey {
        case id, template, platforms, minAppVersion, maxAppVersion
        case startsAt, endsAt, rolloutPercent, priority, reshowPolicy
        case showInWhatsNew, title, body, image, accentColor, buttons
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        template = try container.decode(Template.self, forKey: .template)
        platforms = try container.decode([String].self, forKey: .platforms)
        minAppVersion = try container.decodeIfPresent(CampaignAppVersion.self, forKey: .minAppVersion)
        maxAppVersion = try container.decodeIfPresent(CampaignAppVersion.self, forKey: .maxAppVersion)
        startsAt = try container.decodeIfPresent(Date.self, forKey: .startsAt)
        endsAt = try container.decodeIfPresent(Date.self, forKey: .endsAt)
        rolloutPercent = try container.decodeIfPresent(Double.self, forKey: .rolloutPercent) ?? 100
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        reshowPolicy = try container.decode(ReshowPolicy.self, forKey: .reshowPolicy)
        showInWhatsNew = try container.decodeIfPresent(Bool.self, forKey: .showInWhatsNew) ?? false
        title = try container.decode(CampaignText.self, forKey: .title)
        body = try container.decode(CampaignText.self, forKey: .body)
        image = try container.decodeIfPresent(CampaignImage.self, forKey: .image)
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor)
        buttons = try container.decodeIfPresent([CampaignButton].self, forKey: .buttons) ?? []
    }

    public init(
        id: String,
        template: Template,
        platforms: [String] = ["ios"],
        minAppVersion: CampaignAppVersion? = nil,
        maxAppVersion: CampaignAppVersion? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        rolloutPercent: Double = 100,
        priority: Int = 0,
        reshowPolicy: ReshowPolicy,
        showInWhatsNew: Bool = false,
        title: CampaignText,
        body: CampaignText,
        image: CampaignImage? = nil,
        accentColor: String? = nil,
        buttons: [CampaignButton] = []
    ) {
        self.id = id
        self.template = template
        self.platforms = platforms
        self.minAppVersion = minAppVersion
        self.maxAppVersion = maxAppVersion
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.rolloutPercent = rolloutPercent
        self.priority = priority
        self.reshowPolicy = reshowPolicy
        self.showInWhatsNew = showInWhatsNew
        self.title = title
        self.body = body
        self.image = image
        self.accentColor = accentColor
        self.buttons = buttons
    }
}

/// A user-visible string in every supported locale, resolved per device.
public struct CampaignText: Sendable, Equatable, Decodable {
    public let en: String
    public let ja: String?

    public init(en: String, ja: String? = nil) {
        self.en = en
        self.ja = ja
    }

    /// Resolves against a BCP-47 language identifier, falling back to English.
    public func resolved(languageCode: String) -> String {
        if languageCode.lowercased().hasPrefix("ja"), let ja { return ja }
        return en
    }
}

public struct CampaignImage: Sendable, Equatable, Decodable {
    /// https URL or a site-relative path resolved against the API base URL.
    public let light: String
    public let dark: String?
    /// Width / height, used to reserve layout before the image loads.
    public let aspectRatio: Double?
    public let alt: CampaignText?

    public init(light: String, dark: String? = nil, aspectRatio: Double? = nil, alt: CampaignText? = nil) {
        self.light = light
        self.dark = dark
        self.aspectRatio = aspectRatio
        self.alt = alt
    }
}

public struct CampaignButton: Sendable, Equatable, Decodable {
    public enum Role: String, Sendable, Decodable {
        case primary
        case secondary
    }

    public enum Action: Sendable, Equatable {
        /// Opened in-app; the URL is https by server-side validation.
        case openURL(URL)
        case dismiss
    }

    public let label: CampaignText
    public let action: Action
    public let role: Role

    enum CodingKeys: String, CodingKey {
        case label, action, role
    }

    enum ActionCodingKeys: String, CodingKey {
        case type, url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(CampaignText.self, forKey: .label)
        role = try container.decodeIfPresent(Role.self, forKey: .role) ?? .primary
        let actionContainer = try container.nestedContainer(keyedBy: ActionCodingKeys.self, forKey: .action)
        let type = try actionContainer.decode(String.self, forKey: .type)
        switch type {
        case "openURL":
            let urlString = try actionContainer.decode(String.self, forKey: .url)
            guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url,
                    in: actionContainer,
                    debugDescription: "campaign button URL must be a valid https URL"
                )
            }
            action = .openURL(url)
        case "dismiss":
            action = .dismiss
        default:
            // An action this build cannot perform makes the whole campaign
            // unrenderable; throwing here drops the campaign, not the catalog.
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: actionContainer,
                debugDescription: "unsupported campaign button action \(type)"
            )
        }
    }

    public init(label: CampaignText, action: Action, role: Role = .primary) {
        self.label = label
        self.action = action
        self.role = role
    }
}

/// The decoded `/api/campaigns` payload.
public struct CampaignCatalog: Sendable, Equatable, Decodable {
    /// The newest catalog schema this build understands.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let campaigns: [Campaign]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, campaigns
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.supportedSchemaVersion else {
            // A newer schema may have changed field semantics; render nothing
            // rather than guessing.
            campaigns = []
            return
        }
        var elements = try container.nestedUnkeyedContainer(forKey: .campaigns)
        var decoded: [Campaign] = []
        while !elements.isAtEnd {
            if let campaign = try? elements.decode(Campaign.self) {
                decoded.append(campaign)
            } else {
                // Skip the malformed/unsupported element and keep the rest.
                _ = try? elements.decode(UnkeyedPlaceholder.self)
            }
        }
        campaigns = decoded
    }

    public init(schemaVersion: Int = CampaignCatalog.supportedSchemaVersion, campaigns: [Campaign]) {
        self.schemaVersion = schemaVersion
        self.campaigns = campaigns
    }

    /// Decodes a catalog payload with the campaign date strategy applied.
    public static func decode(from data: Data) throws -> CampaignCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseISOInstant(value) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "expected an ISO-8601 instant, got \(value)"
                ))
            }
            return date
        }
        return try decoder.decode(CampaignCatalog.self, from: data)
    }

    /// `ISO8601DateFormatter` is documented thread-safe, so shared instances
    /// avoid two allocations per campaign date during catalog decodes.
    private nonisolated(unsafe) static let fractionalInstantFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainInstantFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseISOInstant(_ value: String) -> Date? {
        fractionalInstantFormatter.date(from: value) ?? plainInstantFormatter.date(from: value)
    }
}

/// Consumes one unknown element of any JSON shape while scanning a lossy array.
private struct UnkeyedPlaceholder: Decodable {
    init(from decoder: any Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}
