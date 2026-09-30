public import Foundation
public import Observation

/// What the bubble shows, filled by `PageInfoController` from the tab, the
/// engine (`PageInfoProviding`) and the profile's `SitePermissionStore`.
@Observable
public final class PageInfoModel {
    public internal(set) var site = PageInfoSite(url: nil, kind: .empty)
    public internal(set) var page: PageInfoPage = .main
    public internal(set) var permissions: [SitePermissionState] = []
    /// Every permission the engine supports, for the permission subpage.
    public internal(set) var supported: Set<SitePermissionKind> = []
    /// nil while loading.
    public internal(set) var siteData: SiteDataSummary?
    /// Parsed chain, leaf first; nil while loading.
    public internal(set) var certificates: [PageInfoCertificate]?
    public internal(set) var certificateFailure: String?
    /// A change needs a reload to apply (Chrome's reload infobar).
    public internal(set) var needsReload = false

    public init() {}

    public var resettableCount: Int { PageInfoPermissionList.resettableCount(permissions) }

    /// Chrome's "About this page" row: shown for public web pages. cmux opens
    /// the same "About this result" search Chrome's side panel loads.
    public var showsAboutThisPage: Bool {
        guard site.isWeb, let host = site.host, host.contains("."), !host.hasSuffix(".local") else { return false }
        return !host.allSatisfy { $0.isNumber || $0 == "." } && !host.contains(":")
    }

    public var aboutThisPageURL: URL? {
        guard showsAboutThisPage, let url = site.url else { return nil }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: "About \(url.absoluteString)"), URLQueryItem(name: "tbm", value: "ilp")]
        return components?.url
    }

    /// The leaf certificate verified for the page's connection.
    public var isCertificateValid: Bool {
        guard case .web(let connection) = site.kind else { return false }
        switch connection {
        case .secure, .mixedContent: return certificateFailure == nil
        case .insecure, .certificateError, .dangerous: return false
        }
    }

    /// State text under a permission row (Chrome `PageInfoUI::PermissionStateToUIString`).
    public static func stateText(_ state: SitePermissionState) -> String {
        if state.isInUse { return PageInfoStrings.usingNow }
        switch (state.kind, state.setting) {
        case (.sound, .allow): return state.isDefault ? PageInfoStrings.automaticByDefault : PageInfoStrings.allowed
        case (.sound, .block): return PageInfoStrings.muted
        case (_, .allow): return state.isDefault ? PageInfoStrings.allowedByDefault : PageInfoStrings.allowed
        case (_, .block): return state.isDefault ? PageInfoStrings.notAllowedByDefault : PageInfoStrings.notAllowed
        case (let kind, .ask): return PageInfoStrings.askText(kind) ?? PageInfoStrings.ask
        }
    }

    /// A choice's title in the permission subpage and Site settings.
    public static func choiceTitle(_ setting: SitePermissionSetting, kind: SitePermissionKind) -> String {
        let isDefault = setting == kind.defaultSetting
        switch setting {
        case .ask: return isDefault ? PageInfoStrings.askDefault : PageInfoStrings.ask
        case .allow:
            if kind == .sound { return isDefault ? PageInfoStrings.automaticByDefault : PageInfoStrings.allow }
            return isDefault ? PageInfoStrings.allowDefault : PageInfoStrings.allow
        case .block:
            if kind == .sound { return PageInfoStrings.mute }
            return isDefault ? PageInfoStrings.blockDefault : PageInfoStrings.block
        }
    }
}
