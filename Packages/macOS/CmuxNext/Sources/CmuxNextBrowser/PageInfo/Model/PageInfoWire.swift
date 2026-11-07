import Foundation

/// The Page Info bubble's wire (webviews/src/pages/page-info): the state the React page draws
/// (`cmux.page-info.state`) and the commands it sends back (`cmux.page-info.command`). Plain
/// Foundation JSON: this module does not link the page host.
extension PageInfoModel {
    /// The bubble's state as JSON, in the page's `PageInfoModel` shape
    /// (webviews/src/browser-chrome/page-info/model.ts). The page words kinds and settings itself.
    public var wireState: [String: Any] {
        var state: [String: Any] = [
            "page": page.wire,
            "site": site.wire,
            "permissions": permissions.map { ["kind": $0.kind.rawValue, "setting": $0.setting.rawValue, "isDefault": $0.isDefault, "isInUse": $0.isInUse] },
            "siteData": siteData.map { data -> Any in
                ["firstPartyCookies": data.firstPartyCookies, "siteCount": data.siteCount,
                 "thirdPartyPolicy": data.thirdPartyPolicy == .blocked ? "blocked" : "allowed"]
            } ?? NSNull(),
            "certificate": certificateRow ?? NSNull(),
            "certificateWarningsOff": certificateWarningsOff,
            "certificateWarningScope": certificateWarningScope == .profile ? "profile" : "site",
            "needsReload": needsReload,
            "showsAboutThisPage": showsAboutThisPage,
        ]
        if let certificateFailure { state["certificateFailure"] = certificateFailure }
        return state
    }

    /// The security page's certificate row: https pages whose chain is loading or not empty.
    private var certificateRow: [String: Any]? {
        guard site.url?.scheme == "https", certificates.map({ !$0.isEmpty }) ?? true else { return nil }
        var row: [String: Any] = ["valid": isCertificateValid]
        if let issuer = certificates?.first?.issuer, let name = issuer.commonName ?? issuer.organization { row["issuer"] = name }
        return row
    }
}

extension PageInfoPage {
    var wire: [String: Any] {
        switch self {
        case .main: ["type": "main"]
        case .security: ["type": "security"]
        case .cookies: ["type": "cookies"]
        case .permission(let kind): ["type": "permission", "kind": kind.rawValue]
        }
    }

    init?(wire: Any?) {
        guard let wire = wire as? [String: Any] else { return nil }
        switch wire["type"] as? String {
        case "main": self = .main
        case "security": self = .security
        case "cookies": self = .cookies
        case "permission":
            guard let kind = (wire["kind"] as? String).flatMap(SitePermissionKind.init(rawValue:)) else { return nil }
            self = .permission(kind)
        default: return nil
        }
    }
}

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

extension PageInfoCommand {
    /// A command the page sent (`{type, ...}`); nil for one it may not send.
    public init?(wire: [String: Any]) {
        switch wire["type"] as? String {
        case "show":
            guard let page = PageInfoPage(wire: wire["page"]) else { return nil }
            self = .show(page)
        case "showCertificate": self = .showCertificate
        case "setPermission":
            guard let kind = (wire["kind"] as? String).flatMap(SitePermissionKind.init(rawValue:)),
                  let setting = (wire["setting"] as? String).flatMap(SitePermissionSetting.init(rawValue:)),
                  kind.choices.contains(setting) else { return nil }
            self = .setPermission(kind, setting)
        case "resetPermissions": self = .resetPermissions
        case "siteSettings": self = .siteSettings
        case "manageSiteData": self = .manageSiteData
        case "deleteSiteData": self = .deleteSiteData(domain: wire["domain"] as? String)
        case "aboutThisPage": self = .aboutThisPage
        case "reenableCertificateWarnings": self = .reenableCertificateWarnings
        case "reload": self = .reload
        case "close": self = .close
        default: return nil
        }
    }
}
