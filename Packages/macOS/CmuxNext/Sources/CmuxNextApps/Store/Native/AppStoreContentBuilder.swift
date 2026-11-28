import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// Builds the store's column for the model's tab (or listing) at one width. The column is rebuilt when the
/// model or the width changes; it keeps no state of its own.
@MainActor
struct AppStoreContentBuilder {
    let model: AppStoreModel
    let width: CGFloat

    typealias L = AppStoreLayout

    func build() -> NSView {
        var views: [NSView] = []
        if let notice = model.notice { views.append(L.label(notice, font: Typography.body, ink: .secondary, width: width)) }
        if let error = model.error { views.append(L.label(error, font: Typography.body, ink: .danger, width: width, selectable: true)) }
        if let listing = model.listing {
            views += self.listing(listing)
        } else if model.tab == .community {
            views += model.communityRef.map(communityListing) ?? community()
        } else if !model.query.isEmpty {
            views += search()
        } else {
            switch model.tab {
            case .today: views += today()
            case .discover: views += discover()
            case .community: break
            case .categories: views += categories()
            case .updates: views += updates()
            case .installed: views += installed()
            }
        }
        let column = L.stack(views, spacing: Metrics.space5)
        let shown = model.listing != nil || (model.tab == .community && model.communityRef != nil) ? "listing" : model.tab.rawValue
        column.setAccessibilityIdentifier("cmux.appStore.content.\(shown)")
        return column
    }

    // MARK: Tabs

    /// Today (cut 1): the featured heroes and the newest versions.
    private func today() -> [NSView] {
        guard let catalog = loaded(model.catalog) else { return [catalogState()] }
        var views = heroes(featured(catalog))
        let recent = model.sections?.first { $0.kind == .recent }
        let rows = recent.map(model.items(of:)) ?? []
        views.append(shelf(recent.map(AppStoreStrings.sectionTitle) ?? AppStoreStrings.newAndUpdated,
                           rows.isEmpty ? Array(model.storeItems.prefix(8)) : rows))
        return views
    }

    /// Discover (#44805's browse): the featured heroes, then one shelf per section the owner serves.
    private func discover() -> [NSView] {
        guard let catalog = loaded(model.catalog) else { return [catalogState()] }
        var views = heroes(featured(catalog))
        if let sections = model.sections {
            for section in sections where section.kind != .featured {
                let rows = model.items(of: section)
                if !rows.isEmpty { views.append(shelf(AppStoreStrings.sectionTitle(section), rows)) }
            }
        } else {
            views.append(shelf(AppStoreStrings.allApps, model.storeItems))
        }
        return views
    }

    /// Categories: a grid of the categories, then the list of the one picked.
    private func categories() -> [NSView] {
        if let category = model.category {
            var views: [NSView] = [backButton(AppStoreStrings.categories),
                                   L.label(AppStoreStrings.category(category), font: headingFont)]
            switch model.categoryItems {
            case .loaded(let items):
                let rows = items.filter(\.presentable)
                views.append(rows.isEmpty ? L.state(AppStoreStrings.noMatches, width: width) : grid(rows.map(row)))
            case .failed(let reason):
                views.append(L.state(AppStoreStrings.loadFailed, detail: reason, width: width) { model.open(category: category) })
            case .idle, .loading:
                views.append(L.state(AppStoreStrings.loading, width: width))
            }
            return views
        }
        guard loaded(model.catalog) != nil else { return [catalogState()] }
        let ids: [String]
        if let sections = model.sections?.compactMap(\.category), !sections.isEmpty {
            ids = sections
        } else {
            var seen: [String] = []
            for item in model.storeItems { for category in item.categories where !seen.contains(category) { seen.append(category) } }
            ids = seen
        }
        guard !ids.isEmpty else { return [L.state(AppStoreStrings.noMatches, width: width)] }
        return [L.label(AppStoreStrings.categories, font: headingFont), grid(ids.map(categoryTile))]
    }

    /// Updates: every installed app with a newer version, its What's New and Update; Update All on top.
    private func updates() -> [NSView] {
        var header: [NSView] = [L.label(AppStoreStrings.updates, font: headingFont), L.spacer()]
        switch model.updates {
        case .idle, .loading:
            return [L.stack(header, vertical: false, spacing: Metrics.space2), L.state(AppStoreStrings.updatesLoading, width: width)]
        case .failed(let reason):
            return [L.stack(header, vertical: false, spacing: Metrics.space2),
                    L.state(AppStoreStrings.loadFailed, detail: reason, width: width) { model.reload() }]
        case .loaded(let updates):
            guard !updates.isEmpty else {
                return [L.stack(header, vertical: false, spacing: Metrics.space2), L.state(AppStoreStrings.updatesEmpty, width: width)]
            }
            header.append(AppStoreButton(AppStoreStrings.updateAll, style: .primary, identifier: "cmux.appStore.updateAll") { model.updateAll() })
            let bar = L.fixedWidth(L.stack(header, vertical: false, spacing: Metrics.space2), width)
            return [bar] + updates.map(updateRow)
        }
    }

    /// Installed: each installed app with Open and Hide/Show or Remove.
    private func installed() -> [NSView] {
        let title = L.label(AppStoreStrings.installed, font: headingFont)
        switch model.installed {
        case .idle, .loading: return [title, L.state(AppStoreStrings.loading, width: width)]
        case .failed(let reason): return [title, L.state(AppStoreStrings.loadFailed, detail: reason, width: width) { model.reload() }]
        case .loaded(let rows):
            guard !rows.isEmpty else {
                return [title, L.state(AppStoreStrings.noneInstalled, detail: AppStoreStrings.noneInstalledHint, width: width)]
            }
            return [title] + rows.map(installedRow)
        }
    }

    private func search() -> [NSView] {
        switch model.searchResults {
        case .idle, .loading: return [L.state(AppStoreStrings.loading, width: width)]
        case .failed(let reason): return [L.state(AppStoreStrings.loadFailed, detail: reason, width: width)]
        case .loaded(let items):
            let rows = items.filter(\.presentable)
            return rows.isEmpty ? [L.state(AppStoreStrings.noMatches, width: width)] : [grid(rows.map(row))]
        }
    }

    // MARK: Pieces

    var headingFont: NSFont { Typography.system(size: TypeScale.heading, weight: TypeScale.emphasis) }

    private func loaded(_ load: AppStoreLoad<[AppStoreItem]>) -> [AppStoreItem]? { load.value }

    /// The catalog's loading or failed state.
    private func catalogState() -> NSView {
        if case .failed(let reason) = model.catalog {
            return L.state(AppStoreStrings.loadFailed, detail: reason, width: width) { model.reload() }
        }
        return L.state(AppStoreStrings.loading, width: width)
    }

    /// The featured listings: the owner's `featured` section, else the first-party listings (as #44805).
    private func featured(_ catalog: [AppStoreItem]) -> [AppStoreItem] {
        if let section = model.sections?.first(where: { $0.kind == .featured }) { return Array(model.items(of: section).prefix(2)) }
        return Array(catalog.filter { $0.presentable && $0.tier == .firstParty }.prefix(2))
    }

    /// One hero card per featured listing (#44805's `hero-rows`).
    private func heroes(_ items: [AppStoreItem]) -> [NSView] {
        items.map { item in
            let container = Metrics.buttonContainer(padding: Metrics.space5)
            let card = AppStoreClickableView(rest: { Palette.hoverFill }, label: item.name) { model.select(item.id) }
            card.corner = container.outerRadius
            let eyebrow = L.label(AppStoreStrings.featured.uppercased(), font: Typography.system(size: TypeScale.caption, weight: TypeScale.emphasis), ink: .tertiary)
            let name = L.stack([AppStoreIconView(item: item, name: item.name, image: model.icons[item.id], side: 64),
                                L.stack([L.label(item.name, font: headingFont), publisherLine(item)], spacing: Metrics.space1)],
                               vertical: false, spacing: Metrics.space3)
            let body = L.stack([eyebrow, name, L.label(item.oneLine, font: Typography.system(size: TypeScale.title), width: width - 2 * container.padding, lines: 2),
                                L.stack(actions(item, open: false), vertical: false, spacing: Metrics.space2)], spacing: Metrics.space3)
            card.addSubview(body)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalToConstant: width),
                body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: container.padding),
                body.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -container.padding),
                body.topAnchor.constraint(equalTo: card.topAnchor, constant: container.padding),
                card.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: container.padding),
            ])
            card.setAccessibilityIdentifier("cmux.appStore.hero.\(item.id)")
            return card
        }
    }

    /// A titled shelf of listing rows in a grid.
    private func shelf(_ title: String, _ items: [AppStoreItem]) -> NSView {
        let body: NSView = items.isEmpty ? L.state(AppStoreStrings.noMatches, width: width) : grid(items.map(row))
        return L.stack([L.label(title, font: Typography.system(size: TypeScale.title, weight: TypeScale.emphasis)), body], spacing: Metrics.space2)
    }

    /// Two columns at a wide width, one at a narrow one.
    func grid(_ cells: [(CGFloat) -> NSView]) -> NSView {
        let columns = width >= 720 ? 2 : 1
        let gap = Metrics.space3
        let cellWidth = ((width - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        let rows: [NSView] = stride(from: 0, to: cells.count, by: columns).map { start in
            let slice = cells[start..<min(start + columns, cells.count)].map { $0(cellWidth) }
            return L.stack(slice, vertical: false, spacing: gap, alignment: .top)
        }
        return L.stack(rows, spacing: gap)
    }

    /// One listing row (#44805's `ListRow`): icon, name, one line and the one-click action; a click opens it.
    private func row(_ item: AppStoreItem) -> (CGFloat) -> NSView {
        { cellWidth in
            let padding = Metrics.space2
            let row = AppStoreClickableView(label: item.name) { model.select(item.id) }
            row.corner = Metrics.buttonContainer(padding: padding).outerRadius
            let buttons = actions(item, open: false)
            let textWidth = cellWidth - 48 - 3 * Metrics.space3 - 2 * padding - 90
            let text = L.stack([L.label(item.name, font: Typography.bodyEmphasized),
                                L.label(item.oneLine, font: Typography.body, ink: .secondary, width: max(textWidth, 80), lines: 2)],
                               spacing: 2)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = L.stack([AppStoreIconView(item: item, name: item.name, image: model.icons[item.id], side: 48), text, L.spacer()] + buttons,
                               vertical: false, spacing: Metrics.space3)
            row.addSubview(line)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: cellWidth),
                line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: padding),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -padding),
                line.topAnchor.constraint(equalTo: row.topAnchor, constant: padding),
                row.bottomAnchor.constraint(equalTo: line.bottomAnchor, constant: padding),
            ])
            row.setAccessibilityIdentifier("cmux.appStore.row.\(item.id)")
            return row
        }
    }

    /// A category tile: its name and how many listings it has.
    private func categoryTile(_ id: String) -> (CGFloat) -> NSView {
        { cellWidth in
            let padding = Metrics.space4
            let tile = AppStoreClickableView(rest: { Palette.hoverFill }, label: AppStoreStrings.category(id)) { model.open(category: id) }
            tile.corner = Metrics.buttonContainer(padding: padding).outerRadius
            let count = model.storeItems.filter { $0.categories.contains(id) }.count
            var lines: [NSView] = [L.label(AppStoreStrings.category(id), font: Typography.system(size: TypeScale.title, weight: TypeScale.emphasis))]
            if count > 0 { lines.append(L.label(String(count), font: Typography.body, ink: .secondary)) }
            let text = L.stack(lines, spacing: 2)
            tile.addSubview(text)
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(equalToConstant: cellWidth),
                text.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: padding),
                text.topAnchor.constraint(equalTo: tile.topAnchor, constant: padding),
                tile.bottomAnchor.constraint(equalTo: text.bottomAnchor, constant: padding),
            ])
            tile.setAccessibilityIdentifier("cmux.appStore.category.\(id)")
            return tile
        }
    }

    private func updateRow(_ update: AppStoreUpdate) -> NSView {
        let item = model.item(update.id)
        let busy = model.busy.contains(update.id)
        let button = AppStoreButton(AppStoreStrings.update, style: .primary, identifier: "cmux.appStore.update.\(update.id)") {
            model.change(.update, app: update.id)
        }
        button.isEnabled = !busy
        var text: [NSView] = [L.label(update.name, font: Typography.bodyEmphasized),
                              L.label(AppStoreStrings.versionLine(update.version), font: Typography.body, ink: .secondary)]
        if let notes = model.updateNotes[update.id] { text.append(changeLines(notes.items, width: width - 48 - 200)) }
        if let failure = update.failure { text.append(L.label(failure, font: Typography.body, ink: .danger, width: width - 200, selectable: true)) }
        let line = L.stack([AppStoreIconView(item: item, name: update.name, image: model.icons[update.id], side: 48),
                            L.stack(text, spacing: 2), L.spacer(), button], vertical: false, spacing: Metrics.space3, alignment: .top)
        return L.fixedWidth(line, width)
    }

    private func installedRow(_ row: AppStoreInstalledRow) -> NSView {
        let item = model.item(row.id)
        let busy = model.busy.contains(row.id)
        var buttons: [NSView] = []
        if row.enabled, !row.hidden {
            buttons.append(AppStoreButton(AppStoreStrings.open, style: .secondary, identifier: "cmux.appStore.open.\(row.id)") { model.open(row.id) })
        }
        let action = row.hideOnly
            ? AppStoreButton(row.hidden ? AppStoreStrings.show : AppStoreStrings.hide, style: .secondary,
                             identifier: "cmux.appStore.\(row.hidden ? "show" : "hide").\(row.id)") { model.setHidden(row.id, hidden: !row.hidden) }
            : AppStoreButton(AppStoreStrings.remove, style: .secondary, identifier: "cmux.appStore.remove.\(row.id)") { model.change(.remove, app: row.id) }
        action.isEnabled = !busy
        buttons.append(action)
        var meta: [NSView] = [L.label(row.version.isEmpty ? "" : AppStoreStrings.versionLine(row.version), font: Typography.body, ink: .secondary)]
        if !row.enabled { meta.append(L.badge(AppStoreStrings.badgeDisabled)) }
        if row.updateVersion != nil { meta.append(L.badge(AppStoreStrings.badgeUpdate)) }
        let text = L.stack([L.label(row.name, font: Typography.bodyEmphasized), L.stack(meta, vertical: false, spacing: Metrics.space2)], spacing: 2)
        let open = AppStoreClickableView(label: row.name) { model.select(row.id) }
        let padding = Metrics.space2
        open.corner = Metrics.buttonContainer(padding: padding).outerRadius
        let line = L.stack([AppStoreIconView(item: item, name: row.name, image: model.icons[row.id], side: 40), text, L.spacer()] + buttons,
                           vertical: false, spacing: Metrics.space3)
        open.addSubview(line)
        NSLayoutConstraint.activate([
            open.widthAnchor.constraint(equalToConstant: width),
            line.leadingAnchor.constraint(equalTo: open.leadingAnchor, constant: padding),
            line.trailingAnchor.constraint(equalTo: open.trailingAnchor, constant: -padding),
            line.topAnchor.constraint(equalTo: open.topAnchor, constant: padding),
            open.bottomAnchor.constraint(equalTo: line.bottomAnchor, constant: padding),
        ])
        open.setAccessibilityIdentifier("cmux.appStore.installed.\(row.id)")
        return open
    }

    /// The listing's one-click action, exactly as #44805's `ItemAction`: Install, else Hide/Show for an app
    /// that is only hidable (first-party), else Remove; Open first when `open` and the app is installed.
    func actions(_ item: AppStoreItem, open: Bool) -> [NSView] {
        let busy = model.busy.contains(item.id)
        var buttons: [AppStoreButton] = []
        if open, item.installed {
            buttons.append(AppStoreButton(AppStoreStrings.open, style: .secondary, identifier: "cmux.appStore.open.\(item.id)") { model.open(item.id) })
        }
        if !item.installed {
            buttons.append(AppStoreButton(AppStoreStrings.install, style: .primary, identifier: "cmux.appStore.install.\(item.id)") {
                model.change(.install, app: item.id)
            })
        } else if item.hideOnly {
            buttons.append(AppStoreButton(item.hidden ? AppStoreStrings.show : AppStoreStrings.hide, style: .secondary,
                                          identifier: "cmux.appStore.\(item.hidden ? "show" : "hide").\(item.id)") {
                model.setHidden(item.id, hidden: !item.hidden)
            })
        } else {
            buttons.append(AppStoreButton(AppStoreStrings.remove, style: .secondary, identifier: "cmux.appStore.remove.\(item.id)") {
                model.change(.remove, app: item.id)
            })
        }
        for button in buttons where button.accessibilityIdentifier() != "cmux.appStore.open.\(item.id)" { button.isEnabled = !busy }
        return buttons
    }

    /// `✓ publisher · Category · Free`, with the state badge.
    func publisherLine(_ item: AppStoreItem, withCategory: Bool = false) -> NSView {
        var parts: [NSView] = []
        if item.publisherVerified {
            let mark = ThemedImageView(image: NSImage.icon(symbol: "checkmark.seal.fill", size: TypeScale.detail))
            mark.ink = .secondary
            mark.setAccessibilityLabel(AppStoreStrings.verified)
            parts.append(mark)
        }
        var words = [item.publisher]
        if withCategory, let category = item.categories.first { words.append(AppStoreStrings.category(category)) }
        if withCategory { words.append(AppStoreStrings.free) }
        parts.append(L.label(words.joined(separator: " · "), font: Typography.body, ink: .secondary))
        if withCategory, item.installed { parts.append(L.badge(item.enabled ? AppStoreStrings.badgeInstalled : AppStoreStrings.badgeDisabled)) }
        return L.stack(parts, vertical: false, spacing: Metrics.space1)
    }

    /// What's New lines: each change's title, with its pull request number when it has one.
    func changeLines(_ items: [AppStoreChangeLine], width: CGFloat) -> NSView {
        L.stack(items.map { line in
            let text = line.pr.map { "• \(line.title) (#\($0))" } ?? "• \(line.title)"
            return L.label(text, font: Typography.body, width: max(width, 120), selectable: true)
        }, spacing: 2)
    }

    /// `‹ <where back goes>`.
    func backButton(_ title: String) -> NSView {
        AppStoreButton("‹ " + title, style: .plain, identifier: "cmux.appStore.back") { model.back() }
    }
}
