import Foundation

/// A per-site permission or content setting Page Info can show
/// (Chromium `ContentSettingsType`s listed in `PageInfo::kPermissionType`,
/// in Chrome's display order).
public nonisolated enum SitePermissionKind: String, CaseIterable, Codable, CodingKeyRepresentable, Hashable, Sendable {
    case location
    case camera
    case microphone
    case notifications
    case javascript
    case images
    case popups
    case sound
    case automaticDownloads
    case midi
    case usb
    case serial
    case hid
    case clipboard

    /// The value a site gets until the user decides (Chrome's defaults).
    public var defaultSetting: SitePermissionSetting {
        switch self {
        case .javascript, .images, .sound: .allow
        case .popups: .block
        case .location, .camera, .microphone, .notifications, .automaticDownloads,
             .midi, .usb, .serial, .hid, .clipboard: .ask
        }
    }

    /// Content settings are allow or block only; permissions can also ask.
    public var allowsAsk: Bool {
        switch self {
        case .javascript, .images, .popups, .sound: false
        default: true
        }
    }

    /// The choices the permission subpage and Site settings offer.
    public var choices: [SitePermissionSetting] {
        allowsAsk ? [.ask, .allow, .block] : [.allow, .block]
    }

    /// Stable id for the CLI and the persisted file.
    public var id: String { rawValue }
}

/// A decision for one site.
public nonisolated enum SitePermissionSetting: String, CaseIterable, Codable, Hashable, Sendable {
    /// Ask the user when the site requests it.
    case ask
    case allow
    case block
}

/// What Page Info shows for one permission of one site.
public nonisolated struct SitePermissionState: Hashable, Sendable {
    public var kind: SitePermissionKind
    /// The effective value: the user's decision, else the default.
    public var setting: SitePermissionSetting
    /// True when the value is the default (no decision stored).
    public var isDefault: Bool
    /// The page is using it now (camera or microphone capturing).
    public var isInUse: Bool

    public init(kind: SitePermissionKind, setting: SitePermissionSetting, isDefault: Bool, isInUse: Bool = false) {
        self.kind = kind
        self.setting = setting
        self.isDefault = isDefault
        self.isInUse = isInUse
    }

    /// The row's toggle: on when allowed.
    public var isOn: Bool { setting == .allow }
}
