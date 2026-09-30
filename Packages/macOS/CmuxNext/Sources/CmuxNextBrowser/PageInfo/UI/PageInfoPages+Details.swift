import AppKit
import CmuxNextDesign

extension PageInfoPages {
    // MARK: Cookies

    func cookiesPage() -> NSView {
        var views: [NSView] = [header(PageInfoStrings.cookiesHeader, subtitle: model.site.displayName, back: true)]
        views.append(padded(PageInfoStyle.label(PageInfoStrings.cookiesDescription, font: PageInfoStyle.captionFont,
                                                color: PageInfoStyle.secondaryText, wraps: true)))
        guard let data = model.siteData else {
            views.append(PageInfoRowView(symbol: nil, title: PageInfoStrings.loading, interactive: false))
            return stack(views)
        }
        if data.thirdPartyPolicy == .blocked {
            views.append(PageInfoRowView(symbol: "eye.slash", title: PageInfoStrings.thirdPartyCookies,
                                         subtitle: PageInfoStrings.thirdPartyBlocked, interactive: false))
        }
        let counts = [PageInfoStrings.cookieCount(data.firstPartyCookies), PageInfoStrings.siteCount(data.siteCount)]
        let manage = PageInfoRowView(symbol: "tray.full", title: PageInfoStrings.manageSiteData,
                                     subtitle: counts.joined(separator: " · "), accessory: .externalLink,
                                     identifier: "pageInfo.manageSiteData")
        manage.toolTip = PageInfoStrings.manageSiteDataTooltip
        manage.onActivate = { send(.manageSiteData) }
        views.append(manage)
        return stack(views)
    }

    // MARK: One permission

    func permissionPage(_ kind: SitePermissionKind) -> NSView {
        let name = PageInfoStrings.name(kind)
        var views: [NSView] = [header(name, subtitle: model.site.displayName, back: true)]
        let state = model.permissions.first { $0.kind == kind }
            ?? SitePermissionState(kind: kind, setting: kind.defaultSetting, isDefault: true)
        let toggle = PageInfoRowView(symbol: Self.symbol(kind, blocked: state.setting == .block), title: name,
                                     subtitle: PageInfoModel.stateText(state), accessory: .toggle(state.isOn),
                                     identifier: "pageInfo.permissionToggle")
        toggle.onToggle = { on in send(.setPermission(kind, on ? kind.enabledSetting : .block)) }
        views.append(toggle)
        views.append(separator())
        for choice in kind.choices {
            let row = PageInfoRowView(symbol: choice == state.setting ? "checkmark" : "circle.dashed",
                                      title: PageInfoModel.choiceTitle(choice, kind: kind),
                                      identifier: "pageInfo.choice.\(choice.rawValue)")
            row.setAccessibilityRole(.radioButton)
            row.setAccessibilityValue(choice == state.setting ? 1 : 0)
            row.onActivate = { send(.setPermission(kind, choice)) }
            views.append(row)
        }
        views.append(separator())
        let manage = PageInfoRowView(symbol: "gearshape", title: PageInfoStrings.manage, accessory: .externalLink,
                                     identifier: "pageInfo.manage")
        manage.onActivate = { send(.siteSettings) }
        views.append(manage)
        return stack(views)
    }

    // MARK: Words and symbols

    static func shortSummary(_ connection: PageInfoConnection) -> String {
        switch connection {
        case .secure: PageInfoStrings.secureSummary
        case .insecure, .certificateError: PageInfoStrings.notSecureSummary
        case .mixedContent: PageInfoStrings.mixedSummary
        case .dangerous: PageInfoStrings.dangerousSummary
        }
    }

    static func longSummary(_ connection: PageInfoConnection) -> String {
        switch connection {
        case .secure: PageInfoStrings.secureSummary
        case .insecure, .certificateError: PageInfoStrings.notSecureSummaryLong
        case .mixedContent: PageInfoStrings.mixedSummaryLong
        case .dangerous: PageInfoStrings.dangerousSummary
        }
    }

    static func details(_ connection: PageInfoConnection) -> String {
        switch connection {
        case .secure: PageInfoStrings.secureDetails
        case .insecure, .certificateError: PageInfoStrings.notSecureDetails
        case .mixedContent: PageInfoStrings.mixedDetails
        case .dangerous: PageInfoStrings.dangerousDetails
        }
    }

    static func connectionSymbol(_ connection: PageInfoConnection) -> String {
        switch connection {
        case .secure: "lock"
        case .insecure, .mixedContent: PageInfoIndicator.Symbol.notSecure
        case .certificateError, .dangerous: PageInfoIndicator.Symbol.dangerous
        }
    }

    static func isDanger(_ connection: PageInfoConnection) -> Bool {
        switch connection {
        case .certificateError, .dangerous: true
        case .secure, .insecure, .mixedContent: false
        }
    }

    /// Chrome draws a crossed-out icon for a blocked permission.
    static func symbol(_ kind: SitePermissionKind, blocked: Bool) -> String {
        switch kind {
        case .location: blocked ? "location.slash" : "location"
        case .camera: blocked ? "video.slash" : "video"
        case .microphone: blocked ? "mic.slash" : "mic"
        case .notifications: blocked ? "bell.slash" : "bell"
        case .javascript: "curlybraces"
        case .images: "photo"
        case .popups: "arrow.up.forward.app"
        case .sound: blocked ? "speaker.slash" : "speaker.wave.2"
        case .automaticDownloads: "arrow.down.circle"
        case .midi: "pianokeys"
        case .usb: "cable.connector"
        case .serial: "cable.connector.horizontal"
        case .hid: "gamecontroller"
        case .clipboard: "doc.on.clipboard"
        case .sensors: "gyroscope"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .fileEditing: "doc.badge.gearshape"
        case .windowManagement: "macwindow.on.rectangle"
        case .localFonts: "textformat"
        case .backgroundSync: "arrow.triangle.2.circlepath"
        case .autoPictureInPicture: "pip"
        case .thirdPartySignIn: "person.badge.key"
        case .insecureContent: blocked ? "exclamationmark.shield" : "shield.slash"
        }
    }
}
