import Foundation

/// The site as the Page Info windows' pages read it (`PageInfoSite` in
/// webviews/src/browser-chrome/page-info/model.ts). The bubble itself is AppKit and has no wire.
extension PageInfoSite {
    var wire: [String: Any] {
        var site: [String: Any] = ["displayName": displayName]
        switch kind {
        case .web(let connection):
            site["kind"] = "web"
            switch connection {
            case .secure: site["connection"] = "secure"
            case .insecure: site["connection"] = "insecure"
            case .mixedContent: site["connection"] = "mixedContent"
            case .dangerous: site["connection"] = "dangerous"
            case .certificateError: site["connection"] = "certificateError"
            }
        case .file: site["kind"] = "file"
        case .internalPage: site["kind"] = "internalPage"
        case .extensionPage: site["kind"] = "extensionPage"
        case .viewSource: site["kind"] = "viewSource"
        case .devTools: site["kind"] = "devTools"
        case .empty: site["kind"] = "empty"
        }
        return site
    }
}

/// The Page Info windows' wire: the state each window's React page draws (webviews/src/pages/
/// site-settings, site-data and certificate, on `cmux.<page>.state`) in the shapes of
/// webviews/src/browser-chrome/page-info/windows.ts. Pure, so the shapes are tested here.
enum PageInfoWindowWire {
    /// Site settings of `origin`: its usage (nil while loading), every permission this engine
    /// enforces in catalog order with its choices, and whether Reset permissions has work.
    static func siteSettings(site: PageInfoSite, origin: String, supported: Set<SitePermissionKind>,
                             decisions: [SitePermissionKind: SitePermissionSetting], usage: SiteDataSummary?) -> [String: Any] {
        let rows: [[String: Any]] = SitePermissionKind.allCases.filter(supported.contains).map { kind in
            let stored = decisions[kind]
            return ["kind": kind.rawValue, "setting": (stored ?? kind.defaultSetting).rawValue, "isDefault": stored == nil,
                    "choices": kind.choices.map(\.rawValue)]
        }
        let changed = decisions.contains { $0.value != $0.key.defaultSetting }
        return [
            "site": site.wire,
            "origin": origin,
            "usage": usage.map { summary -> Any in ["firstPartyCookies": summary.firstPartyCookies, "siteCount": summary.siteCount] } ?? NSNull(),
            "permissions": rows,
            "canReset": changed,
        ]
    }

    /// The on-device site data dialog: every site that stored data, nil while loading.
    static func siteData(_ data: SiteDataSummary?) -> [String: Any] {
        let entries = data.map { summary -> Any in
            summary.entries.map { entry -> [String: Any] in
                ["domain": entry.domain, "cookieCount": entry.cookieCount, "hasOtherData": entry.hasOtherData,
                 "isThirdParty": entry.isThirdParty]
            }
        }
        return ["entries": entries ?? NSNull()]
    }

    /// The certificate viewer: the chain leaf first, each certificate's fields, fingerprints and
    /// PEM, with dates as milliseconds since 1970 (the page formats them in its language), and the
    /// engine's verification failure.
    static func certificate(chain: [PageInfoCertificate], failure: String?) -> [String: Any] {
        var state: [String: Any] = ["chain": chain.map { wire($0) }]
        if let failure { state["failure"] = failure }
        return state
    }

    private static func wire(_ certificate: PageInfoCertificate) -> [String: Any] {
        [
            "version": certificate.version,
            "serialNumber": certificate.serialNumber,
            "signatureAlgorithm": certificate.signatureAlgorithm,
            "issuer": name(certificate.issuer),
            "subject": name(certificate.subject),
            "notBefore": certificate.notBefore.map { milliseconds($0) as Any } ?? NSNull(),
            "notAfter": certificate.notAfter.map { milliseconds($0) as Any } ?? NSNull(),
            "publicKeyAlgorithm": certificate.publicKeyAlgorithm,
            "subjectAlternativeNames": certificate.subjectAlternativeNames,
            "sha256Fingerprint": certificate.sha256Fingerprint,
            "sha1Fingerprint": certificate.sha1Fingerprint,
            "publicKeySHA256": certificate.publicKeySHA256,
            "pem": certificate.pem,
        ]
    }

    private static func name(_ name: CertificateName) -> [String: Any] {
        var wire: [String: Any] = ["summary": name.summary]
        if let commonName = name.commonName { wire["commonName"] = commonName }
        if let organization = name.organization { wire["organization"] = organization }
        if let unit = name.organizationalUnit { wire["organizationalUnit"] = unit }
        return wire
    }

    private static func milliseconds(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
}

/// What a Page Info window's page sends (`cmux.<page>.command`): the site settings window's
/// permission menus, Reset permissions and Delete data, a site data row's delete, the certificate
/// viewer's Export (a native save panel) and Done or Escape.
enum PageInfoWindowCommand: Equatable {
    case setPermission(SitePermissionKind, SitePermissionSetting)
    case resetPermissions
    /// One site's data, or the window's whole site when nil.
    case deleteSiteData(domain: String?)
    /// Exports the chain from the certificate at `index` (0 is the leaf) to the root as PEM.
    case exportCertificate(index: Int)
    case close

    /// A command the page sent (`{type, ...}`); nil for one it may not send.
    init?(wire: [String: Any]) {
        switch wire["type"] as? String {
        case "setPermission":
            guard let kind = (wire["kind"] as? String).flatMap(SitePermissionKind.init(rawValue:)),
                  let setting = (wire["setting"] as? String).flatMap(SitePermissionSetting.init(rawValue:)),
                  kind.choices.contains(setting) else { return nil }
            self = .setPermission(kind, setting)
        case "resetPermissions": self = .resetPermissions
        case "deleteSiteData":
            let domain = wire["domain"] as? String
            guard domain.map({ !$0.isEmpty }) ?? true else { return nil }
            self = .deleteSiteData(domain: domain)
        case "exportCertificate":
            guard let index = (wire["index"] as? NSNumber)?.intValue, index >= 0 else { return nil }
            self = .exportCertificate(index: index)
        case "close": self = .close
        default: return nil
        }
    }
}
