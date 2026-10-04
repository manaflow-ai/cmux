import Foundation

/// The picker's places (R89): the Locations section at the start folder,
/// the Recent page, and path mode (a query that starts with `/` or `~/`).
extension PickerSession {
    static let recentLocationID = "loc:recent"
    static let locationsSection = PaletteSection(id: "picker.locations", title: PickerStrings.locations, order: -200)

    // MARK: Locations

    /// Recent, then the environment's locations; only at the start folder
    /// and only for an empty query (typing filters the folder).
    func locationItems(_ state: FolderPickerState, rows: PickerPageRows) -> [PaletteItem] {
        guard state.isAtStart else { return [] }
        var items: [PaletteItem] = []
        if !environment.recents.isEmpty {
            var recent = PaletteItem(id: Self.recentLocationID, title: PaletteStrings.sectionRecent, symbol: "clock",
                                     section: Self.locationsSection,
                                     primary: PaletteCommand(id: "enter", title: PickerStrings.openFolder, symbol: "chevron.right",
                                                             effect: .deferred { .replace(self.recentPage(state)) }),
                                     frecencyKey: nil)
            recent.hidesWhenTyping = true
            items.append(recent)
        }
        for (index, place) in environment.locations.enumerated() {
            let id = "loc:\(index):\(place.url.path)"
            rows.locations[id] = place.url
            let row = FolderPickerRow(kind: .folder, url: place.url, isDirectory: true)
            var item = entryItem(row, state: state)
            item = PaletteItem(id: id, title: title(of: place), subtitle: abbreviatePath(place.url.path), symbol: place.symbol,
                               section: Self.locationsSection, primary: item.primary, alternate: item.alternate,
                               secondary: item.secondary, frecencyKey: nil)
            item.hidesWhenTyping = true
            items.append(item)
        }
        return items
    }

    private func title(of place: PickerLocation) -> String {
        switch place.kind {
        case .home: PickerStrings.home
        case .desktop: PickerStrings.area(.desktop)
        case .documents: PickerStrings.area(.documents)
        case .downloads: PickerStrings.area(.downloads)
        case .iCloudDrive: PickerStrings.area(.iCloudDrive)
        case .workspace, .pinned: place.url.lastPathComponent.isEmpty ? place.url.path : place.url.lastPathComponent
        }
    }

    // MARK: Recent

    /// The recent folders and files the mode can choose, newest first. Up
    /// goes back to the start folder.
    func recentPage(_ origin: FolderPickerState) -> PalettePageSpec {
        let rows = PickerPageRows()
        var items: [PaletteItem] = []
        for raw in environment.recents {
            let isFolder = raw.hasSuffix("/")
            let path = isFolder && raw.count > 1 ? String(raw.dropLast()) : raw
            let url = URL(fileURLWithPath: path, isDirectory: isFolder)
            guard isFolder || origin.mode.lists(file: url.lastPathComponent) else { continue }
            if !isFolder, origin.mode.kind == .open(.folders) { continue }
            let row = FolderPickerRow(kind: isFolder ? .folder : .file, url: url, isDirectory: isFolder)
            var item = entryItem(row, state: origin)
            item.subtitle = abbreviatePath(url.deletingLastPathComponent().path)
            item.accessory = nil
            rows.byID[row.id] = row
            items.append(item)
        }
        let back = PaletteCrumb(title: PaletteStrings.sectionRecent) { nil }
        return PalettePageSpec(
            id: "picker.recent", title: PaletteStrings.sectionRecent, placeholder: PickerStrings.chooseItem, symbol: "clock",
            providers: [StaticPaletteProvider(id: "picker.recent", items: items)], keepsSectionOrder: true, ranksPrefixFirst: true,
            onCancel: { self.finish(nil) },
            hierarchy: PaletteHierarchy(
                enter: { item in rows.byID[item.id].flatMap { $0.isDirectory ? self.page(for: origin.moving(to: $0.url), back: origin) : nil } },
                up: { self.page(for: origin) },
                jump: { text in PickerPath.isPath(text) ? self.pathPage(text, origin: origin) : nil }),
            hint: PickerStrings.openHint,
            crumbs: crumbs(origin) + [back])
    }

    // MARK: Path mode

    /// The page of a typed path: the completions of its last segment in
    /// its folder, read off the main actor when the folder changes. Tab or
    /// Right completes the selected segment; Return goes there (a file
    /// picker chooses a file). A query that is no longer a path filters
    /// `origin` again.
    func pathPage(_ text: String, origin: FolderPickerState) -> PalettePageSpec {
        guard let path = PickerPath(text, home: environment.home) else { return page(for: origin, query: text) }
        let target = origin.moving(to: path.folder)
        if PickerPrivacy.area(of: path.folder.path, home: environment.home.path) != nil, let memory = environment.explainer,
           !memory.hasShownExplainer {
            return page(for: target, back: origin)
        }
        let listed = PickerPathListing()
        let environment = environment
        let provider = AsyncPaletteProvider(id: "picker.path") {
            listed.listing = await environment.list(path.folder, origin.mode, FolderPickerState.pageSize)
            return []
        }
        return PalettePageSpec(
            id: "picker.path", title: pageTitle(origin), placeholder: PickerStrings.chooseItem, symbol: "folder",
            providers: [provider], initialQuery: text, keepsSectionOrder: true,
            onCancel: { self.finish(nil) },
            hierarchy: PaletteHierarchy(
                enter: { item in listed.entry(item.id).map { self.pathPage(path.completing($0), origin: origin) } },
                up: { nil },
                jump: { typed in
                    guard let next = PickerPath(typed, home: environment.home) else { return self.page(for: origin, query: typed) }
                    return next.folder == path.folder ? nil : self.pathPage(typed, origin: origin)
                }),
            queryItems: { typed in self.pathItems(PickerPath(typed, home: environment.home) ?? path, listed: listed, origin: origin) },
            filtersByQuery: false,
            hint: PickerStrings.openHint,
            crumbs: crumbs(origin))
    }

    private func pathItems(_ path: PickerPath, listed: PickerPathListing, origin: FolderPickerState) -> [PaletteItem] {
        guard let listing = listed.listing else { return [] }
        var items: [PaletteItem] = []
        if path.segment.isEmpty {
            let folder = origin.moving(to: path.folder)
            items.append(PaletteItem(id: "path.go", title: PickerStrings.goTo(path.typedFolder), symbol: "arrow.right.circle",
                                     section: Self.entriesSection,
                                     primary: PaletteCommand(id: "go", title: PickerStrings.openFolder, effect: .deferred {
                                         .replace(self.page(for: folder, back: origin))
                                     }),
                                     frecencyKey: nil))
        }
        let completions = path.completions(listing.entries)
        listed.byID = [:]
        for entry in completions.prefix(300) {
            let url = path.folder.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
            let id = "path:" + url.path
            listed.byID[id] = entry
            let primary: PaletteCommand = entry.isDirectory
                ? PaletteCommand(id: "go", title: PickerStrings.openFolder, effect: .deferred {
                    .replace(self.page(for: origin.moving(to: url), back: origin))
                })
                : choose(choice(url, mode: origin.mode))
            items.append(PaletteItem(id: id, title: entry.name + (entry.isDirectory ? "/" : ""),
                                     accessory: entry.isGitRepository ? PickerStrings.gitRepository : nil,
                                     symbol: entry.isDirectory ? (entry.isGitRepository ? "arrow.triangle.branch" : "folder") : "doc.text",
                                     section: Self.entriesSection, primary: primary, frecencyKey: nil))
        }
        if let failure = listing.failure {
            items.append(PaletteItem(id: "path.notice", title: failure == .permissionDenied ? PickerStrings.permissionDenied : PickerStrings.notFound,
                                     symbol: "exclamationmark.triangle", section: Self.moreSection, isEnabled: false,
                                     primary: PaletteCommand(id: "none", title: "", effect: .performKeepingOpen {}), frecencyKey: nil))
        } else if completions.isEmpty, !path.segment.isEmpty {
            items.append(PaletteItem(id: "path.notice", title: PickerStrings.noMatch(path.typedFolder), symbol: "magnifyingglass",
                                     section: Self.moreSection, isEnabled: false,
                                     primary: PaletteCommand(id: "none", title: "", effect: .performKeepingOpen {}), frecencyKey: nil))
        }
        return items
    }
}
