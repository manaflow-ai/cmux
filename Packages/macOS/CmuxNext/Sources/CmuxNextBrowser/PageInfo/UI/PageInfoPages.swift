import AppKit
import CmuxNextDesign

/// Builds the bubble's pages from the model. Every control sends a
/// `PageInfoCommand`; nothing here changes state directly.
@MainActor struct PageInfoPages {
    let model: PageInfoModel
    let send: (PageInfoCommand) -> Void

    func build() -> NSView {
        switch model.page {
        case .main: mainPage()
        case .security: securityPage()
        case .cookies: cookiesPage()
        case .permission(let kind): permissionPage(kind)
        }
    }

    // MARK: Main

    private func mainPage() -> NSView {
        let site = model.site
        var views: [NSView] = [header(site.displayName, subtitle: nil, back: false)]
        guard let connection = site.connection else {
            views.append(identityRow(for: site.kind))
            return stack(views)
        }
        let security = PageInfoRowView(
            symbol: Self.connectionSymbol(connection), title: Self.shortSummary(connection),
            accessory: .chevron, tint: Self.isDanger(connection) ? PageInfoStyle.danger : nil, identifier: "pageInfo.security"
        )
        security.toolTip = PageInfoStrings.showConnectionDetails
        security.onActivate = { send(.show(.security)) }
        views.append(security)

        if !model.permissions.isEmpty {
            views.append(separator())
            views += model.permissions.map(permissionRow)
            let count = model.resettableCount
            if count > 0 {
                let reset = PageInfoRowView(symbol: "arrow.counterclockwise",
                                            title: count == 1 ? PageInfoStrings.resetPermission : PageInfoStrings.resetPermissions,
                                            identifier: "pageInfo.reset")
                reset.onActivate = { send(.resetPermissions) }
                views.append(reset)
            }
        }
        if model.needsReload { views.append(reloadNotice()) }
        views.append(separator())

        let cookies = PageInfoRowView(symbol: "cylinder.split.1x2", title: PageInfoStrings.cookiesHeader,
                                      accessory: .chevron, identifier: "pageInfo.cookies")
        cookies.toolTip = PageInfoStrings.cookiesTooltip
        cookies.onActivate = { send(.show(.cookies)) }
        views.append(cookies)

        let settings = PageInfoRowView(symbol: "gearshape", title: PageInfoStrings.siteSettings,
                                       accessory: .externalLink, identifier: "pageInfo.siteSettings")
        settings.toolTip = PageInfoStrings.siteSettingsTooltip
        settings.onActivate = { send(.siteSettings) }
        views.append(settings)

        if model.showsAboutThisPage {
            let about = PageInfoRowView(symbol: "doc.text.magnifyingglass", title: PageInfoStrings.aboutThisPage,
                                        subtitle: PageInfoStrings.aboutThisPageDescription, accessory: .externalLink,
                                        identifier: "pageInfo.about")
            about.onActivate = { send(.aboutThisPage) }
            views.append(about)
        }
        return stack(views)
    }

    private func permissionRow(_ state: SitePermissionState) -> NSView {
        let row = PageInfoRowView(
            symbol: Self.symbol(state.kind, blocked: state.setting == .block),
            title: PageInfoStrings.name(state.kind), subtitle: PageInfoModel.stateText(state),
            accessory: .toggle(state.isOn), identifier: "pageInfo.permission.\(state.kind.rawValue)"
        )
        row.toolTip = PageInfoStrings.permissionDetailsTooltip(PageInfoStrings.name(state.kind))
        row.onToggle = { on in send(.setPermission(state.kind, on ? state.kind.enabledSetting : .block)) }
        row.onActivate = { send(.show(.permission(state.kind))) }
        return row
    }

    private func reloadNotice() -> NSView {
        let text = PageInfoStyle.label(PageInfoStrings.reloadToApply, font: PageInfoStyle.captionFont,
                                       color: PageInfoStyle.secondaryText, wraps: true)
        let button = PageInfoRowView(symbol: "arrow.clockwise", title: PageInfoStrings.reload, identifier: "pageInfo.reload")
        button.onActivate = { send(.reload) }
        return stack([padded(text), button], spacing: 2)
    }

    private func identityRow(for kind: PageInfoSiteKind) -> NSView {
        let (symbol, text): (String, String) = switch kind {
        case .file: (PageInfoIndicator.Symbol.file, PageInfoStrings.filePage)
        case .extensionPage: (PageInfoIndicator.Symbol.extensionPage, PageInfoStrings.extensionPage)
        case .viewSource: (PageInfoIndicator.Symbol.product, PageInfoStrings.viewSourcePage)
        case .devTools: (PageInfoIndicator.Symbol.product, PageInfoStrings.devToolsPage)
        case .internalPage, .empty, .web: (PageInfoIndicator.Symbol.product, PageInfoStrings.internalPage)
        }
        return PageInfoRowView(symbol: symbol, title: text, interactive: false)
    }

    // MARK: Security

    private func securityPage() -> NSView {
        let site = model.site
        var views: [NSView] = [header(PageInfoStrings.securityHeader, subtitle: site.displayName, back: true)]
        guard let connection = site.connection else { return stack(views) }
        let danger = Self.isDanger(connection)
        let summary = PageInfoRowView(symbol: Self.connectionSymbol(connection), title: Self.longSummary(connection),
                                      tint: danger ? PageInfoStyle.danger : nil, interactive: false)
        views.append(summary)
        var details = [Self.details(connection)]
        if case .certificateError = connection {
            details.insert(PageInfoStrings.identityNotVerified, at: 0)
            if let reason = model.certificateFailure { details.append(reason) }
        }
        views.append(padded(PageInfoStyle.label(details.joined(separator: "\n\n"), font: PageInfoStyle.captionFont,
                                                color: PageInfoStyle.secondaryText, wraps: true)))
        if site.url?.scheme == "https", model.certificates.map({ !$0.isEmpty }) ?? true {
            views.append(separator())
            let valid = model.isCertificateValid
            let row = PageInfoRowView(symbol: valid ? "checkmark.seal" : "xmark.seal",
                                      title: valid ? PageInfoStrings.certificateValid : PageInfoStrings.certificateInvalid,
                                      accessory: .externalLink, tint: valid ? nil : PageInfoStyle.danger,
                                      identifier: "pageInfo.certificate")
            let issuer = model.certificates?.first?.issuer.commonName ?? model.certificates?.first?.issuer.organization
            row.toolTip = valid && issuer != nil ? PageInfoStrings.showCertificateIssuedBy(issuer ?? "") : PageInfoStrings.showCertificate
            row.onActivate = { send(.showCertificate) }
            views.append(row)
        }
        return stack(views)
    }

    // MARK: Shared pieces

    func header(_ title: String, subtitle: String?, back: Bool) -> NSView {
        let header = PageInfoHeaderView(title: title, subtitle: subtitle, showsBack: back)
        header.onBack = { send(.show(.main)) }
        header.onClose = { send(.close) }
        return header
    }

    func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    func padded(_ view: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        let inset = PageInfoStyle.rowInset
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: PageInfoStyle.iconColumn + inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
        return container
    }

    func stack(_ views: [NSView], spacing: CGFloat = 2) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
}
