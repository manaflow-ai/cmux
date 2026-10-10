import AppKit
import CmuxNextDesign

/// Site settings for one origin (like `chrome://settings/content/
/// siteDetails`): usage with Delete data, every permission this engine can
/// enforce with an Ask/Allow/Block menu, and Reset permissions.
final class SiteSettingsWindow: PageInfoWindow {
    let origin: String
    private let store: SitePermissionStore
    private let provider: any PageInfoProviding
    private let send: (PageInfoCommand) -> Void
    private let usage = PageInfoStyle.label("", font: PageInfoStyle.bodyFont, color: PageInfoStyle.secondaryText)
    private var menus: [SitePermissionKind: NSPopUpButton] = [:]
    private let reset = NSButton()
    private var observation: ObservationLoop?

    init(origin: String, site: PageInfoSite, store: SitePermissionStore, provider: any PageInfoProviding,
         send: @escaping (PageInfoCommand) -> Void) {
        self.origin = origin
        self.store = store
        self.provider = provider
        self.send = send
        super.init(title: PageInfoStrings.siteSettingsTitle(site.displayName), size: CGSize(width: 460, height: 520))
        setAccessibilityIdentifier("cmux.pageInfo.siteSettings")
        usage.stringValue = PageInfoStrings.loading
        let deleteData = NSButton(title: PageInfoStrings.deleteData, target: self, action: #selector(deleteSiteData))
        reset.title = PageInfoStrings.resetPermissions
        reset.target = self
        reset.action = #selector(resetPermissions)

        let grid = NSGridView()
        grid.rowSpacing = PageInfoStyle.spacing * 2
        grid.columnSpacing = PageInfoStyle.inset
        for kind in SitePermissionKind.allCases where provider.supportedSitePermissions.contains(kind) {
            let icon = ThemedImageView(image: PageInfoStyle.symbol(PageInfoPages.symbol(kind, blocked: false)) ?? NSImage())
            icon.themeTint = { PageInfoStyle.text }
            let name = PageInfoStyle.label(PageInfoStrings.name(kind), font: PageInfoStyle.bodyFont, color: PageInfoStyle.text)
            let menu = NSPopUpButton()
            for choice in kind.choices {
                menu.addItem(withTitle: PageInfoModel.choiceTitle(choice, kind: kind))
                menu.lastItem?.representedObject = choice.rawValue
            }
            menu.target = self
            menu.action = #selector(choose(_:))
            menu.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            menus[kind] = menu
            grid.addRow(with: [icon, name, menu])
        }
        grid.column(at: 0).width = PageInfoStyle.iconColumn
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .trailing
        grid.setContentHuggingPriority(.required, for: .vertical)
        // One width for every value menu (the widest title), so the
        // dropdowns align.
        let menuWidth = menus.values.map { $0.intrinsicContentSize.width }.max() ?? 0
        for menu in menus.values {
            menu.translatesAutoresizingMaskIntoConstraints = false
            menu.widthAnchor.constraint(equalToConstant: menuWidth).isActive = true
        }

        let views: [NSView] = [
            PageInfoWindow.sectionTitle(PageInfoStrings.usage), usage, deleteData,
            PageInfoWindow.sectionTitle(PageInfoStrings.permissions), grid, reset,
            PageInfoStyle.label(PageInfoStrings.engineLimited, font: PageInfoStyle.captionFont, color: PageInfoStyle.tertiaryText, wraps: true),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PageInfoStyle.spacing * 1.5
        stack.setCustomSpacing(PageInfoStyle.inset * 2, after: deleteData)
        stack.edgeInsets = NSEdgeInsets(top: PageInfoStyle.inset * 1.5, left: PageInfoStyle.inset * 1.5,
                                        bottom: PageInfoStyle.inset * 1.5, right: PageInfoStyle.inset * 1.5)
        installContent(stack)
        observation = ObservationLoop { [weak self] in self?.syncMenus() }
        Task { [weak self, provider] in
            let data = await provider.pageInfoSiteData(pageHost: URL(string: origin)?.host())
            self?.show(data)
        }
    }

    func show(_ data: SiteDataSummary) {
        usage.stringValue = [PageInfoStrings.cookieCount(data.firstPartyCookies), PageInfoStrings.siteCount(data.siteCount)]
            .joined(separator: " · ")
    }

    private func syncMenus() {
        let decisions = store.decisions[origin] ?? [:]
        for (kind, menu) in menus {
            let setting = decisions[kind] ?? kind.defaultSetting
            menu.selectItem(at: kind.choices.firstIndex(of: setting) ?? 0)
        }
        reset.isEnabled = !store.changedKinds(for: origin).isEmpty
    }

    /// The bubble's page is still on this origin: go through the registry
    /// action; otherwise edit this origin's store entry directly.
    private var isCurrentOrigin: Bool {
        (provider as? any BrowserTab)?.state.url.flatMap(PageInfoSite.origin(of:)) == origin
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let kind = SitePermissionKind(rawValue: raw),
              let value = sender.selectedItem?.representedObject as? String,
              let setting = SitePermissionSetting(rawValue: value) else { return }
        if isCurrentOrigin {
            send(.setPermission(kind, setting))
        } else {
            store.set(setting, kind, for: origin)
            Task { [provider, origin] in await provider.pageInfoDidChange(kind, to: setting, origin: origin) }
        }
    }

    @objc private func resetPermissions() {
        if isCurrentOrigin { return send(.resetPermissions) }
        // The engine keeps its own decisions (Chromium persists content
        // settings): reset each one the store or the engine had, not only
        // the store.
        let stored = store.changedKinds(for: origin)
        store.reset(origin: origin)
        Task { [provider, origin] in
            let live = await provider.pageInfoLivePermissions(origin: origin)
            for kind in stored.union(live.keys) {
                await provider.pageInfoDidChange(kind, to: kind.defaultSetting, origin: origin)
            }
        }
    }

    @objc private func deleteSiteData() {
        guard let host = URL(string: origin)?.host() else { return }
        send(.deleteSiteData(domain: SiteDomain.registrable(host)))
    }
}
