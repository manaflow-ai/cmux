import AppKit
import CmuxNextDesign

/// A listing's page, as #44805's `listing-carousel-sidebar`: the header (icon, name, tagline,
/// `publisher · category · Free`, Open and the one-click action), then the description, the screenshot
/// carousel, Runs on, What's New and Version History on the left, and Shows up in, Permissions and
/// Information in a column on the right. Under 720 points it is one column.
extension AppStoreContentBuilder {
    private var asideWidth: CGFloat { 300 }
    private var twoColumns: Bool { width >= 720 }
    private var mainWidth: CGFloat { twoColumns ? width - asideWidth - Metrics.space6 : width }
    private var factLabelWidth: CGFloat { 110 }

    func listing(_ app: String) -> [NSView] {
        let back = backButton(model.tab.title)
        switch model.detail {
        case .idle, .loading:
            return [back, L.state(AppStoreStrings.loading, width: width)]
        case .failed(let reason):
            return [back, L.state(AppStoreStrings.loadFailed, detail: reason, width: width) { model.select(app) }]
        case .loaded(let detail):
            guard detail.id == app else { return [back, L.state(AppStoreStrings.loading, width: width)] }
            return [back, header(detail), body(detail)]
        }
    }

    private func header(_ detail: AppStoreDetail) -> NSView {
        let item = detail.item
        var title: [NSView] = [L.label(item.name, font: Typography.system(size: TypeScale.heading, weight: TypeScale.emphasis))]
        if let tagline = item.tagline {
            title.append(L.label(tagline, font: Typography.system(size: TypeScale.title), ink: .secondary, width: width - 96 - 260))
        }
        title.append(publisherLine(item, withCategory: true))
        let row = L.stack([AppStoreIconView(item: item, name: item.name, image: model.icons[item.id], side: 96),
                           L.stack(title, spacing: Metrics.space1), L.spacer(),
                           L.stack(actions(item, open: true), vertical: false, spacing: Metrics.space2)],
                          vertical: false, spacing: Metrics.space4, alignment: .top)
        row.setAccessibilityIdentifier("cmux.appStore.listing.header")
        return L.fixedWidth(row, width)
    }

    private func body(_ detail: AppStoreDetail) -> NSView {
        var main: [NSView] = []
        if !detail.item.summary.isEmpty {
            main.append(L.label(detail.item.summary, font: Typography.body, width: mainWidth, selectable: true))
        }
        if let carousel = carousel(detail) { main.append(carousel) }
        if !detail.deployTargets.isEmpty {
            main.append(section(AppStoreStrings.runsOn, [L.stack(detail.deployTargets.map {
                L.label("• " + AppStoreStrings.deployTarget($0), font: Typography.body, width: mainWidth)
            }, spacing: 2)]))
        }
        if let news = detail.whatsNew { main.append(whatsNew(news, versions: detail.versions)) }
        if !detail.versions.isEmpty { main.append(versionHistory(detail.versions)) }
        var aside: [NSView] = []
        if let shows = showsUpIn(detail.contributes) { aside.append(shows) }
        aside.append(permissions(detail.scopes))
        aside.append(information(detail))
        guard twoColumns else { return L.stack(main + aside, spacing: Metrics.space5) }
        let left = L.fixedWidth(L.stack(main, spacing: Metrics.space5), mainWidth)
        let right = L.fixedWidth(L.stack(aside, spacing: Metrics.space5), asideWidth)
        return L.stack([left, right], vertical: false, spacing: Metrics.space6, alignment: .top)
    }

    /// The selected screenshot large, the others as thumbnails under it (a click shows one).
    private func carousel(_ detail: AppStoreDetail) -> NSView? {
        let shots = model.screenshots
        guard !shots.isEmpty else { return nil }
        let index = min(model.shotIndex, shots.count - 1)
        var views: [NSView] = [AppStoreShotView(image: shots[index], width: mainWidth, label: AppStoreStrings.screenshot(index + 1))]
        if shots.count > 1 {
            let thumbs: [NSView] = shots.enumerated().map { offset, image in
                let padding: CGFloat = 2
                let tile = AppStoreClickableView(rest: { offset == index ? Palette.selectionFill : nil },
                                                 label: AppStoreStrings.screenshot(offset + 1)) { model.showShot(offset) }
                tile.corner = Metrics.buttonContainer(padding: padding).outerRadius
                let shot = AppStoreShotView(image: image, width: 92, label: AppStoreStrings.screenshot(offset + 1))
                tile.addSubview(shot)
                NSLayoutConstraint.activate([
                    shot.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: padding),
                    shot.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -padding),
                    shot.topAnchor.constraint(equalTo: tile.topAnchor, constant: padding),
                    shot.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -padding),
                ])
                tile.setAccessibilityIdentifier("cmux.appStore.listing.shot.\(offset)")
                return tile
            }
            views.append(L.stack(thumbs, vertical: false, spacing: Metrics.space2, alignment: .top))
        }
        let stack = L.stack(views, spacing: Metrics.space2)
        stack.setAccessibilityIdentifier("cmux.appStore.listing.screenshots")
        return stack
    }

    /// What's New: the newest version's changes (the owner's `whats_new`).
    private func whatsNew(_ news: AppStoreWhatsNew, versions: [AppStoreVersionRow]) -> NSView {
        var lines: [NSView] = [L.label(versionAndDate(news.version, date: versions.first { $0.version == news.version }?.date),
                                       font: Typography.body, ink: .secondary)]
        lines.append(changeLines(news.items, width: mainWidth))
        let view = section(AppStoreStrings.whatsNew, lines)
        view.setAccessibilityIdentifier("cmux.appStore.listing.whatsNew")
        return view
    }

    /// Version History: every published version, newest first, with its date and tag.
    private func versionHistory(_ versions: [AppStoreVersionRow]) -> NSView {
        let rows: [NSView] = versions.prefix(20).map { row in
            var words = [versionAndDate(row.version, date: row.date)]
            if let tag = row.tag, !tag.isEmpty, tag != "v" + row.version { words.append(tag) }
            if let commit = row.commit, !commit.isEmpty { words.append(String(commit.prefix(7))) }
            var line: [NSView] = [L.label(words.joined(separator: " · "), font: Typography.body)]
            if let engines = row.engines, !engines.isEmpty {
                line.append(L.label(AppStoreStrings.requires(engines), font: Typography.body, ink: .tertiary))
            }
            return L.stack(line, vertical: false, spacing: Metrics.space2)
        }
        let view = section(AppStoreStrings.versionHistory, rows)
        view.setAccessibilityIdentifier("cmux.appStore.listing.versions")
        return view
    }

    private func versionAndDate(_ version: String, date: Date?) -> String {
        let text = AppStoreStrings.versionLine(version)
        guard let date else { return text }
        return text + " · " + date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Shows up in: one row per place, with every title the app puts there.
    private func showsUpIn(_ contributes: [AppStoreContribution]) -> NSView? {
        guard !contributes.isEmpty else { return nil }
        var places: [(place: String, titles: [String])] = []
        for item in contributes {
            let place = AppStoreStrings.place(item.kind) ?? ""
            if let at = places.firstIndex(where: { $0.place == place }) { places[at].titles.append(item.title) }
            else { places.append((place, [item.title])) }
        }
        return section(AppStoreStrings.showsUpIn, places.map { fact($0.place, $0.titles) })
    }

    /// Permissions in plain words, grouped by what they reach; required before optional, riskier first.
    private func permissions(_ scopes: [AppStoreScope]) -> NSView {
        guard !scopes.isEmpty else {
            return section(AppStoreStrings.permissions, [L.label(AppStoreStrings.noPermissions, font: Typography.body, ink: .secondary)])
        }
        let order = ["restricted", "sensitive", "standard"]
        let sorted = scopes.sorted {
            ($0.optional ? 1 : 0, order.firstIndex(of: $0.risk) ?? 2, $0.scope) < ($1.optional ? 1 : 0, order.firstIndex(of: $1.risk) ?? 2, $1.scope)
        }
        var groups: [(heading: String?, rows: [AppStoreScope])] = []
        for scope in sorted {
            let heading = AppStoreStrings.scopeHeading(scope.scope)
            if let heading, let at = groups.firstIndex(where: { $0.heading == heading }) { groups[at].rows.append(scope) }
            else { groups.append((heading, [scope])) }
        }
        let asideText = twoColumns ? asideWidth : width
        let views: [NSView] = groups.map { group in
            var lines: [NSView] = []
            if let heading = group.heading { lines.append(L.label(heading, font: Typography.bodyEmphasized)) }
            for row in group.rows {
                var parts: [NSView] = [L.label(row.reason.isEmpty ? row.scope : row.reason, font: Typography.body, ink: .secondary,
                                               width: asideText, selectable: true)]
                var badges: [NSView] = []
                if row.optional { badges.append(L.badge(AppStoreStrings.optional)) }
                if let risk = AppStoreStrings.risk(row.risk) { badges.append(L.badge(risk)) }
                if !badges.isEmpty { parts.append(L.stack(badges, vertical: false, spacing: Metrics.space1)) }
                lines.append(L.stack(parts, spacing: 2))
            }
            return L.stack(lines, spacing: Metrics.space1)
        }
        let view = section(AppStoreStrings.permissions, views)
        view.setAccessibilityIdentifier("cmux.appStore.listing.permissions")
        return view
    }

    /// Information: developer, category, version (and the cmux it needs), the repository link.
    private func information(_ detail: AppStoreDetail) -> NSView {
        let item = detail.item
        var rows: [NSView] = [fact(AppStoreStrings.developer, [item.publisher])]
        if !item.categories.isEmpty {
            rows.append(fact(AppStoreStrings.category, [item.categories.map { AppStoreStrings.category($0) }.joined(separator: ", ")]))
        }
        let latest = detail.versions.first { $0.version == item.version } ?? detail.versions.first
        var version = [item.version]
        if let engines = latest?.engines, !engines.isEmpty { version.append(AppStoreStrings.requires(engines)) }
        rows.append(fact(AppStoreStrings.version, version))
        if let repository = item.repository, repository.scheme == "https" {
            rows.append(AppStoreButton(AppStoreStrings.repository + " ↗", style: .plain, identifier: "cmux.appStore.listing.repository") {
                model.openLink(repository)
            })
        }
        return section(AppStoreStrings.information, rows)
    }

    /// A titled block of the listing.
    private func section(_ title: String, _ views: [NSView]) -> NSView {
        L.stack([L.heading(title)] + views, spacing: Metrics.space2)
    }

    /// A fact row: its label on the left, its lines on the right.
    private func fact(_ label: String, _ values: [String]) -> NSView {
        let valueWidth = (twoColumns ? asideWidth : width) - factLabelWidth - Metrics.space2
        let left = L.fixedWidth(L.label(label, font: Typography.body, ink: .secondary), factLabelWidth)
        let right = L.stack(values.map { L.label($0, font: Typography.body, width: valueWidth, selectable: true) }, spacing: 2)
        return L.stack([left, right], vertical: false, spacing: Metrics.space2, alignment: .top)
    }
}
