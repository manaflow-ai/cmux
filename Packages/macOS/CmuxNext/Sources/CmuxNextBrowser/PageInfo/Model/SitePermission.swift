import Foundation

/// A per-site permission or content setting Page Info can show
/// (Chromium `ContentSettingsType`s listed in `PageInfo::kPermissionType`,
/// in Chromium's display order).
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
    // Chromium-only kinds (WebKit has no per-site hook for them).
    case sensors
    case bluetooth
    case fileEditing
    case windowManagement
    case localFonts
    case backgroundSync
    case autoPictureInPicture
    case thirdPartySignIn
    case insecureContent

    /// The value a site gets until the user decides (Chromium's defaults).
    public var defaultSetting: SitePermissionSetting {
        switch self {
        case .javascript, .images, .sound, .sensors, .backgroundSync, .thirdPartySignIn: .allow
        case .popups, .insecureContent: .block
        case .location, .camera, .microphone, .notifications, .automaticDownloads,
             .midi, .usb, .serial, .hid, .clipboard, .bluetooth, .fileEditing,
             .windowManagement, .localFonts, .autoPictureInPicture: .ask
        }
    }

    /// Content settings are allow or block only; permissions can also ask.
    public var allowsAsk: Bool {
        switch self {
        case .javascript, .images, .popups, .sound, .sensors, .backgroundSync, .thirdPartySignIn, .insecureContent: false
        default: true
        }
    }

    /// Chromium's guard kinds (device choosers, file editing) are ask or
    /// block: a site is granted single devices or files, never all of them.
    public var allowsAllow: Bool {
        switch self {
        case .usb, .serial, .hid, .bluetooth, .fileEditing: false
        default: true
        }
    }

    /// The choices the permission subpage and Site settings offer.
    public var choices: [SitePermissionSetting] {
        if !allowsAsk { return [.allow, .block] }
        return allowsAllow ? [.ask, .allow, .block] : [.ask, .block]
    }

    /// What the row's toggle stores when switched on.
    public var enabledSetting: SitePermissionSetting { allowsAllow ? .allow : .ask }

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

    /// The row's toggle: on when allowed (guard kinds: when not blocked).
    public var isOn: Bool { kind.allowsAllow ? setting == .allow : setting != .block }
}
