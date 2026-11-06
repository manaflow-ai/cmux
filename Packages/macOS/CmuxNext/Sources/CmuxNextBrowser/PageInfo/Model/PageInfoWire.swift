import Foundation

/// The Page Info bubble's wire (webviews/src/pages/page-info): the state the React page draws
/// (`cmux.page-info.state`) and the commands it sends back (`cmux.page-info.command`). Plain
/// Foundation JSON: this module does not link the page host.
extension PageInfoModel {
    /// The bubble's state as JSON. The page turns kinds and settings into text itself.
    public var wireState: [String: Any] {
        var state: [String: Any] = [
            "page": page.wire,
            "site": site.wire,
            "permissions": permissions.map { ["kind": $0.kind.rawValue, "setting": $0.setting.rawValue, "isDefault": $0.isDefault, "isInUse": $0.isInUse] },
            "choices": Dictionary(uniqueKeysWithValues: permissions.map { ($0.kind.rawValue, $0.kind.choices.map(\.rawValue)) }),
            "resettableCount": resettableCount,
            "needsReload": needsReload,
            "showsAboutThisPage": showsAboutThisPage,
            "certificateValid": isCertificateValid,
            "certificateWarningsOff": certificateWarningsOff,
            "certificateWarningScope": certificateWarningScope == .profile ? "profile" : "site",
        ]
        if let certificateFailure { state["certificateFailure"] = certificateFailure }
        if let certificates {
            state["certificates"] = certificates.map { certificate in
                ["issuer": certificate.issuer.commonName ?? certificate.issuer.organization ?? "",
                 "subject": certificate.subject.commonName ?? certificate.subject.organization ?? ""]
            }
        }
        if let siteData {
            state["siteData"] = [
                "thirdPartyBlocked": siteData.thirdPartyPolicy == .blocked,
                "entries": siteData.entries.map { ["domain": $0.domain, "cookieCount": $0.cookieCount, "hasOtherData": $0.hasOtherData, "isThirdParty": $0.isThirdParty] },
            ]
        }
        return state
    }
}

extension PageInfoPage {
    var wire: [String: Any] {
        switch self {
        case .main: ["kind": "main"]
        case .security: ["kind": "security"]
        case .cookies: ["kind": "cookies"]
        case .permission(let kind): ["kind": "permission", "permission": kind.rawValue]
        }
    }

    init?(wire: Any?) {
        guard let wire = wire as? [String: Any] else { return nil }
        switch wire["kind"] as? String {
        case "main": self = .main
        case "security": self = .security
        case "cookies": self = .cookies
        case "permission":
            guard let kind = (wire["permission"] as? String).flatMap(SitePermissionKind.init(rawValue:)) else { return nil }
            self = .permission(kind)
        default: return nil
        }
    }
}

extension PageInfoSite {
    var wire: [String: Any] {
        var site: [String: Any] = ["displayName": displayName]
        if let url { site["url"] = url.absoluteString }
        if let host { site["host"] = host }
        switch kind {
        case .web(let connection):
            site["kind"] = "web"
            switch connection {
            case .secure: site["connection"] = "secure"
            case .insecure: site["connection"] = "insecure"
            case .mixedContent: site["connection"] = "mixedContent"
            case .dangerous: site["connection"] = "dangerous"
            case .certificateError(let code):
                site["connection"] = "certificateError"
                if let code { site["certificateErrorCode"] = code }
            }
        case .file: site["kind"] = "file"
        case .internalPage: site["kind"] = "internal"
        case .extensionPage: site["kind"] = "extension"
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
            guard let kind = (wire["permission"] as? String).flatMap(SitePermissionKind.init(rawValue:)),
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
