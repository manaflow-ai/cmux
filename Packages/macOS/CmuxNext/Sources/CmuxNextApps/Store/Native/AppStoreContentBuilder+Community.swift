import AppKit
import CmuxNextDesign

/// The Community tab: extensions and setups people publish (the owner's `source: "community"` cache), with the
/// kind filter, the sort, each row's downloads and last update, the person's other devices' installs, and a
/// listing page with the README.
extension AppStoreContentBuilder {
    func community() -> [NSView] {
        var views: [NSView] = [L.label(AppStoreStrings.community, font: headingFont), communityControls()]
        switch model.community {
        case .idle, .loading:
            views.append(L.state(AppStoreStrings.loading, width: width))
        case .failed(let reason):
            views.append(L.state(AppStoreStrings.loadFailed, detail: reason, width: width) { model.loadCommunity(refresh: true) })
        case .loaded(let page):
            if let error = page.error {
                // One quiet line: the cache still shows.
                views.append(L.stack([L.label(error, font: Typography.body, ink: .secondary, width: width - 120),
                                      AppStoreButton(AppStoreStrings.retry, style: .plain, identifier: "cmux.appStore.community.retry") {
                                          model.loadCommunity(refresh: true)
                                      }], vertical: false, spacing: Metrics.space2))
            }
            if !page.elsewhere.isEmpty {
                views.append(L.stack([L.label(AppStoreStrings.onOtherDevices, font: Typography.system(size: TypeScale.title, weight: TypeScale.emphasis)),
                                      grid(page.elsewhere.map { communityRow($0, elsewhere: true) })], spacing: Metrics.space2))
            }
            // A refresh says nothing over cached rows (RFD 0143); `apps-changed` swaps them when the fetch lands.
            views.append(page.rows.isEmpty ? L.state(page.updating ? AppStoreStrings.loading : AppStoreStrings.noMatches, width: width)
                                           : grid(page.rows.map { communityRow($0, elsewhere: false) }))
        }
        return views
    }

    /// The kind filter (All, Extensions, Setups) and the sort.
    private func communityControls() -> NSView {
        let kinds: [(String?, String)] = [(nil, AppStoreStrings.allKinds), ("extension", AppStoreStrings.kindExtensions), ("setup", AppStoreStrings.kindSetups)]
        let kindButtons: [NSView] = kinds.map { kind, title in
            let button = AppStoreButton(title, style: model.communityKind == kind ? .secondary : .plain,
                                        identifier: "cmux.appStore.community.kind.\(kind ?? "all")") { model.filterCommunity(kind: kind) }
            button.setAccessibilityValue(model.communityKind == kind)
            return button
        }
        let sortButtons: [NSView] = AppStoreCommunityWire.sorts.map { sort in
            let button = AppStoreButton(AppStoreStrings.communitySort(sort), style: model.communitySort == sort ? .secondary : .plain,
                                        identifier: "cmux.appStore.community.sort.\(sort)") { model.sortCommunity(sort) }
            button.setAccessibilityValue(model.communitySort == sort)
            return button
        }
        let kindsRow = L.stack(kindButtons, vertical: false, spacing: Metrics.space1)
        let sortRow = L.stack([L.label(AppStoreStrings.sortBy, font: Typography.body, ink: .secondary)] + sortButtons,
                              vertical: false, spacing: Metrics.space1)
        if width >= 820 { return L.fixedWidth(L.stack([kindsRow, L.spacer(), sortRow], vertical: false, spacing: Metrics.space3), width) }
        return L.stack([kindsRow, sortRow], spacing: Metrics.space2)
    }

    /// One community row: initial tile, name, one line, `author · N downloads · Updated <date>`, Install.
    private func communityRow(_ row: AppStoreCommunityRow, elsewhere: Bool) -> (CGFloat) -> NSView {
        { cellWidth in
            let padding = Metrics.space2
            let tile = AppStoreClickableView(label: row.name) { model.selectCommunity(row.ref) }
            tile.corner = Metrics.buttonContainer(padding: padding).outerRadius
            let textWidth = max(cellWidth - 48 - 3 * Metrics.space3 - 2 * padding - 130, 80)
            let text = L.stack([L.label(row.name, font: Typography.bodyEmphasized),
                                L.label(row.oneLine, font: Typography.body, ink: .secondary, width: textWidth, lines: 2),
                                L.label(communityMeta(row), font: Typography.system(size: TypeScale.detail), ink: .tertiary)], spacing: 2)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = L.stack([AppStoreIconView(item: nil, name: row.name, image: nil, side: 48), text, L.spacer()]
                                   + communityAction(row, elsewhere: elsewhere), vertical: false, spacing: Metrics.space3)
            tile.addSubview(line)
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(equalToConstant: cellWidth),
                line.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: padding),
                line.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -padding),
                line.topAnchor.constraint(equalTo: tile.topAnchor, constant: padding),
                tile.bottomAnchor.constraint(equalTo: line.bottomAnchor, constant: padding),
            ])
            tile.setAccessibilityIdentifier("cmux.appStore.community.row.\(row.ref)")
            return tile
        }
    }

    /// Install (or, for another device's row, Install on this Mac) through the consent card; Installed when it is.
    private func communityAction(_ row: AppStoreCommunityRow, elsewhere: Bool) -> [NSView] {
        if row.installed && !elsewhere {
            if let app = row.installApp {
                return [AppStoreButton(AppStoreStrings.open, style: .secondary, identifier: "cmux.appStore.open.\(app)") { model.open(app) }]
            }
            return [L.badge(AppStoreStrings.badgeInstalled)]
        }
        guard let app = row.installApp else { return [] }
        let button = AppStoreButton(elsewhere ? AppStoreStrings.installOnThisMac : AppStoreStrings.install, style: .primary,
                                    identifier: "cmux.appStore.install.\(app)") { model.installCommunity(row) }
        button.isEnabled = !model.busy.contains(app)
        return [button]
    }

    private func communityMeta(_ row: AppStoreCommunityRow) -> String {
        var parts: [String] = []
        if !row.author.isEmpty { parts.append(row.author) }
        if let device = row.device { parts.append(device) }
        parts.append(AppStoreStrings.downloads(row.downloads))
        if let date = row.updatedAt { parts.append(AppStoreStrings.updated(date.formatted(date: .abbreviated, time: .omitted))) }
        return parts.joined(separator: " · ")
    }

    /// A community listing: header with Install, the README, versions and the facts.
    func communityListing(_ ref: String) -> [NSView] {
        let back = backButton(AppStoreStrings.community)
        switch model.communityDetail {
        case .idle, .loading:
            return [back, L.state(AppStoreStrings.loading, width: width)]
        case .failed(let reason):
            return [back, L.state(AppStoreStrings.loadFailed, detail: reason, width: width) { model.selectCommunity(ref) }]
        case .loaded(let detail):
            guard detail.id == ref else { return [back, L.state(AppStoreStrings.loading, width: width)] }
            let row = detail.row
            var title: [NSView] = [L.label(row.name, font: Typography.system(size: TypeScale.heading, weight: TypeScale.emphasis))]
            if let tagline = row.tagline {
                title.append(L.label(tagline, font: Typography.system(size: TypeScale.title), ink: .secondary, width: width - 96 - 260))
            }
            title.append(L.label(communityMeta(row), font: Typography.body, ink: .secondary))
            let header = L.fixedWidth(L.stack([AppStoreIconView(item: nil, name: row.name, image: nil, side: 96),
                                               L.stack(title, spacing: Metrics.space1), L.spacer(),
                                               L.stack(communityAction(row, elsewhere: false), vertical: false, spacing: Metrics.space2)],
                                              vertical: false, spacing: Metrics.space4, alignment: .top), width)
            let twoColumns = width >= 720
            let asideWidth: CGFloat = 300
            let mainWidth = twoColumns ? width - asideWidth - Metrics.space6 : width
            var main: [NSView] = []
            if !model.communityReadme.isEmpty {
                main.append(AppStoreMarkdownView(blocks: model.communityReadme, width: mainWidth) { url in model.openLink(url) })
            } else if !row.description.isEmpty {
                main.append(L.label(row.description, font: Typography.body, width: mainWidth, selectable: true))
            }
            if !model.communityChangelog.isEmpty {
                main.append(L.stack([L.heading(AppStoreStrings.whatsNew),
                                     AppStoreMarkdownView(blocks: model.communityChangelog, width: mainWidth) { url in model.openLink(url) }],
                                    spacing: Metrics.space2))
            }
            if !detail.versions.isEmpty {
                main.append(L.stack([L.heading(AppStoreStrings.versionHistory)] + detail.versions.prefix(20).map { version in
                    var words = [AppStoreStrings.versionLine(version.version)]
                    if let date = version.date { words.append(date.formatted(date: .abbreviated, time: .omitted)) }
                    if let commit = version.commit, !commit.isEmpty { words.append(String(commit.prefix(7))) }
                    return L.label(words.joined(separator: " · "), font: Typography.body)
                }, spacing: Metrics.space2))
            }
            let aside = communityFacts(detail, width: twoColumns ? asideWidth : width)
            let body: NSView = twoColumns
                ? L.stack([L.fixedWidth(L.stack(main, spacing: Metrics.space5), mainWidth), L.fixedWidth(aside, asideWidth)],
                          vertical: false, spacing: Metrics.space6, alignment: .top)
                : L.stack(main + [aside], spacing: Metrics.space5)
            return [back, header, body]
        }
    }

    private func communityFacts(_ detail: AppStoreCommunityDetail, width: CGFloat) -> NSView {
        let row = detail.row
        let labelWidth: CGFloat = 110
        func fact(_ label: String, _ value: String) -> NSView {
            L.stack([L.fixedWidth(L.label(label, font: Typography.body, ink: .secondary), labelWidth),
                     L.label(value, font: Typography.body, width: width - labelWidth - Metrics.space2, selectable: true)],
                    vertical: false, spacing: Metrics.space2, alignment: .top)
        }
        var rows: [NSView] = [L.heading(AppStoreStrings.information)]
        if !row.author.isEmpty { rows.append(fact(AppStoreStrings.developer, row.author)) }
        rows.append(fact(AppStoreStrings.kind, row.kind == "setup" ? AppStoreStrings.kindSetup : AppStoreStrings.kindExtension))
        if !row.categories.isEmpty { rows.append(fact(AppStoreStrings.category, row.categories.map { AppStoreStrings.category($0) }.joined(separator: ", "))) }
        if let version = row.version { rows.append(fact(AppStoreStrings.version, version)) }
        if let minimum = row.minCmux { rows.append(fact(AppStoreStrings.version, AppStoreStrings.requires(minimum))) }
        rows.append(fact(AppStoreStrings.downloadsLabel, String(row.downloads)))
        if let date = row.updatedAt { rows.append(fact(AppStoreStrings.lastUpdated, date.formatted(date: .abbreviated, time: .omitted))) }
        if let license = detail.license { rows.append(fact(AppStoreStrings.license, license)) }
        if let repository = row.repository ?? row.pageURL, repository.scheme == "https" {
            rows.append(AppStoreButton(AppStoreStrings.repository + " ↗", style: .plain, identifier: "cmux.appStore.listing.repository") {
                model.openLink(repository)
            })
        }
        return L.stack(rows, spacing: Metrics.space2)
    }
}
