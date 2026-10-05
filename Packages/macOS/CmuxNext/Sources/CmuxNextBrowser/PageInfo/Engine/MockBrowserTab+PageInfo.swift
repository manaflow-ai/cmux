public import Foundation

/// Canned Page Info data for `MockBrowserTab` (demos and tests).
public struct MockPageInfoData {
    public var settings = SiteSettingsRegistry(persistence: { _ in MemorySitePermissionPersistence() })
    public var supported: Set<SitePermissionKind> = Set(SitePermissionKind.allCases)
    public var certificates: [Data] = []
    /// Cookie domains the page's jar holds (".cdn.example.com").
    public var cookieDomains: [String] = []
    public var otherDataDomains: [String] = []
    public var thirdPartyPolicy: ThirdPartyCookiePolicy = .allowed
    public var live: [SitePermissionKind: SitePermissionSetting] = [:]
    public var inUse: Set<SitePermissionKind> = []
    /// Every change Page Info pushed to the engine, in order.
    public private(set) var appliedChanges: [(SitePermissionKind, SitePermissionSetting, String)] = []
    public private(set) var deletedDomains: [String] = []
    /// The page was loaded past a certificate warning the user turned off.
    public var certificateWarningsOff = false

    public init() {}

    mutating func recordChange(_ kind: SitePermissionKind, _ setting: SitePermissionSetting, _ origin: String) {
        appliedChanges.append((kind, setting, origin))
    }

    mutating func delete(_ domains: [String]) {
        let targets = Set(domains.map(SiteDomain.registrable))
        deletedDomains += domains
        cookieDomains.removeAll { targets.contains(SiteDomain.registrable($0)) }
        otherDataDomains.removeAll { targets.contains(SiteDomain.registrable($0)) }
    }
}

extension MockBrowserTab: PageInfoProviding {
    public var pageInfoSettings: SiteSettingsRegistry { pageInfoFake.settings }
    public var supportedSitePermissions: Set<SitePermissionKind> { pageInfoFake.supported }
    public var pageInfoInUse: Set<SitePermissionKind> { pageInfoFake.inUse }

    public func pageInfoCertificateChain() async -> [Data] { pageInfoFake.certificates }

    public func pageInfoSiteData(pageHost: String?) async -> SiteDataSummary {
        .grouping(cookieDomains: pageInfoFake.cookieDomains, otherDataDomains: pageInfoFake.otherDataDomains,
                  pageHost: pageHost, thirdPartyPolicy: pageInfoFake.thirdPartyPolicy)
    }

    public func pageInfoDeleteSiteData(domains: [String]) async { pageInfoFake.delete(domains) }

    public func pageInfoLivePermissions(origin: String) async -> [SitePermissionKind: SitePermissionSetting] { pageInfoFake.live }

    public func pageInfoDidChange(_ kind: SitePermissionKind, to setting: SitePermissionSetting, origin: String) async {
        pageInfoFake.recordChange(kind, setting, origin)
    }
}

extension MockBrowserTab: BrowserCertificateWarningRevoking {
    public var certificateWarningsTurnedOff: Bool { pageInfoFake.certificateWarningsOff }
    public var certificateWarningScope: BrowserCertificateWarningScope { engineKind == .cef ? .profile : .site }
    public var canTurnOnCertificateWarnings: Bool { pageInfoFake.certificateWarningsOff }

    public func turnOnCertificateWarnings() async -> Bool {
        guard pageInfoFake.certificateWarningsOff else { return false }
        pageInfoFake.certificateWarningsOff = false
        reload()
        return true
    }
}
