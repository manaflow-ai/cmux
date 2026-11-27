import Foundation

/// Rows to palette items: what Return, Cmd-Return and the Actions menu do
/// on each, and the save picker's rows made from the typed name.
extension PickerSession {
    static let actionsSection = PaletteSection(id: "picker.actions", title: "", order: -300)
    /// One section for the level, as the reference picker: recent first,
    /// folders before files, by name.
    static let entriesSection = PaletteSection(id: "picker.entries", title: "", order: 0)
    static let moreSection = PaletteSection(id: "picker.more", title: "", order: 50)

    func items(for rows: [FolderPickerRow], state: FolderPickerState) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if state.mode.allowsMultiple, !marked.isEmpty {
            items.append(PaletteItem(id: "picker.openMarked", title: PickerStrings.openSelected(marked.count),
                                     symbol: "checkmark.circle", section: Self.actionsSection,
                                     primary: choose(marked), frecencyKey: nil))
        }
        items += rows.flatMap { item(for: $0, state: state) }
        if state.mode.offersAllFiles {
            let title = state.mode.showsAllFiles ? PickerStrings.showOnly(state.mode.filter.summary) : PickerStrings.showAllFiles
            items.append(PaletteItem(id: "picker.allFiles", title: title, symbol: "line.3.horizontal.decrease.circle",
                                     section: Self.moreSection,
                                     primary: PaletteCommand(id: "allFiles", title: title, effect: .deferred {
                                         .replace(self.page(for: state.togglingAllFiles()))
                                     }),
                                     frecencyKey: nil))
        }
        if state.mode.isSave || state.mode.choosesFolders { items.append(newFolderItem(state)) }
        return items
    }

    private func item(for row: FolderPickerRow, state: FolderPickerState) -> [PaletteItem] {
        let path = abbreviatePath(row.url.path)
        switch row.kind {
        case .useFolder:
            return [PaletteItem(id: row.id, title: PickerStrings.useThisFolder, subtitle: path, symbol: "checkmark.circle",
                                section: Self.actionsSection, primary: choose([row.url]), frecencyKey: nil)]
        case .folder, .file:
            return [entryItem(row, state: state)]
        case .more(let count):
            return [PaletteItem(id: row.id, title: PickerStrings.showMore(count), symbol: "ellipsis.circle", section: Self.moreSection,
                                primary: PaletteCommand(id: "more", title: PickerStrings.showMore(count), effect: .deferred {
                                    .replace(self.page(for: state.showingMore()))
                                }),
                                frecencyKey: nil)]
        case .notice(let notice):
            return noticeItems(notice, state: state)
        }
    }

    func entryItem(_ row: FolderPickerRow, state: FolderPickerState) -> PaletteItem {
        let isMarked = marked.contains(row.url)
        let symbol = isMarked ? "checkmark.circle.fill"
            : row.isDirectory ? (row.isGitRepository ? "arrow.triangle.branch" : "folder") : "doc.text"
        // A folder enters on Return unless folders are what is chosen.
        let enters = row.isDirectory && !state.mode.choosesFolders
        let primary = enters ? enterCommand(row.url, from: state) : choose(choice(row.url, mode: state.mode))
        let accessory = isMarked ? PickerStrings.selected
            : [row.isGitRepository ? PickerStrings.gitRepository : nil, row.isRecent ? PaletteStrings.sectionRecent : nil]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
        var item = PaletteItem(id: row.id, title: row.name, accessory: accessory.isEmpty ? nil : accessory, symbol: symbol,
                               section: Self.entriesSection, primary: primary, frecencyKey: nil)
        if state.mode.allowsMultiple, !state.mode.isSave, !enters {
            let title = isMarked ? PickerStrings.deselect : PickerStrings.select
            item.alternate = PaletteCommand(id: "mark", title: title, symbol: "checkmark.circle", effect: .performKeepingOpen {
                self.toggleMark(row.url)
            })
        }
        if row.isDirectory, state.mode.choosesFolders { item.secondary = [enterCommand(row.url, from: state)] }
        if row.isHidden { item.queryPrefix = "." }
        return item
    }

    private func noticeItems(_ notice: FolderPickerNotice, state: FolderPickerState) -> [PaletteItem] {
        let title: String = switch notice {
        case .permissionDenied: PickerStrings.permissionDenied
        case .notFound: PickerStrings.notFound
        case .empty: PickerStrings.empty
        case .unreadable: PickerStrings.unreadable
        }
        var items = [PaletteItem(id: "picker.notice", title: title,
                                 subtitle: notice == .permissionDenied ? PickerStrings.permissionDetail : nil,
                                 symbol: notice == .empty ? "tray" : "exclamationmark.triangle", section: Self.moreSection,
                                 isEnabled: false, primary: PaletteCommand(id: "none", title: "", effect: .performKeepingOpen {}),
                                 frecencyKey: nil)]
        if notice == .permissionDenied {
            let url = PickerPrivacy.settingsURL(for: PickerPrivacy.area(of: state.directory.path, home: environment.home.path))
            let open = environment.openSettings
            items.append(PaletteItem(id: "picker.privacySettings", title: PickerStrings.openPrivacySettings, symbol: "gearshape",
                                     section: Self.moreSection,
                                     primary: PaletteCommand(id: "settings", title: PickerStrings.openPrivacySettings,
                                                             effect: .perform { open(url) }),
                                     frecencyKey: nil))
        }
        return items
    }

    private func newFolderItem(_ state: FolderPickerState) -> PaletteItem {
        let create = environment.createFolder
        let spec = PaletteTextInputSpec(
            id: "picker.newFolder", title: PickerStrings.newFolder, placeholder: PickerStrings.folderName, symbol: "folder.badge.plus",
            submitTitle: { PickerStrings.createFolder($0) },
            isValid: { PickerSaveName.isValid($0.trimmingCharacters(in: .whitespaces)) },
            // Deferred: the palette builds the submit row on every keystroke,
            // and the folder is made only when Return runs it.
            next: { name in
                .deferred {
                    let folder = state.directory.appendingPathComponent(name.trimmingCharacters(in: .whitespaces), isDirectory: true)
                    // A failed create leaves the folder as it was.
                    guard (try? create(folder)) != nil else { return .replace(self.page(for: state)) }
                    return .replace(self.page(for: state.moving(to: folder), back: state))
                }
            }
        )
        return PaletteItem(id: "picker.newFolder", title: PickerStrings.newFolder, symbol: "folder.badge.plus", section: Self.moreSection,
                           primary: PaletteCommand(id: "newFolder", title: PickerStrings.newFolder, effect: .textInput(spec)),
                           frecencyKey: nil)
    }

    /// The save picker's rows for the typed `text`: Save, and one Save As
    /// per other allowed type.
    func saveItems(_ text: String, state: FolderPickerState) -> [PaletteItem] {
        let filter = state.mode.filter
        guard let name = PickerSaveName.fileName(text, filter: filter, type: state.saveType) else {
            return [PaletteItem(id: "picker.save", title: PickerStrings.typeAName, symbol: "square.and.arrow.down",
                                section: Self.actionsSection, isEnabled: false,
                                primary: PaletteCommand(id: "none", title: "", effect: .performKeepingOpen {}), frecencyKey: nil)]
        }
        let target = state.directory.appendingPathComponent(name, isDirectory: false)
        let type = filter.types.indices.contains(state.saveType) ? filter.types[state.saveType].name : nil
        let detail = [abbreviatePath(state.directory.path), type].compactMap { $0 }.joined(separator: " · ")
        var items = [PaletteItem(id: "picker.save", title: PickerStrings.save(name), subtitle: detail, symbol: "square.and.arrow.down",
                                 keycaps: ["↩"], section: Self.actionsSection,
                                 primary: PaletteCommand(id: "save", title: PickerStrings.save(name), effect: .deferred {
                                     self.saveEffect(target, text: text, state: state)
                                 }),
                                 frecencyKey: nil)]
        guard filter.types.count > 1 else { return items }
        for (index, other) in filter.types.enumerated() where index != state.saveType {
            guard let ext = other.extensions.first else { continue }
            let base = (text as NSString).deletingPathExtension
            var next = state
            next.saveType = index
            items.append(PaletteItem(id: "picker.saveAs.\(index)", title: PickerStrings.saveAs(other.name, ext),
                                     symbol: "doc.badge.gearshape", section: Self.actionsSection,
                                     primary: PaletteCommand(id: "saveAs", title: PickerStrings.saveAs(other.name, ext),
                                                             effect: .deferred {
                                                                 .replace(self.page(for: next, query: base + "." + ext))
                                                             }),
                                     frecencyKey: nil))
        }
        return items
    }

    /// Save `target`: at once when nothing is there, else after the
    /// overwrite confirmation (the save page comes back on Cancel).
    func saveEffect(_ target: URL, text: String, state: FolderPickerState) -> PaletteEffect {
        let finish: @MainActor () -> Void = { self.finish([target]) }
        guard environment.fileExists(target) else { return .perform(finish) }
        return environment.overwrite.confirm(replacing: target, replace: finish, cancel: page(for: state, query: text))
    }

    /// Opens `folder` in place (the same step Tab and Right take).
    private func enterCommand(_ folder: URL, from state: FolderPickerState) -> PaletteCommand {
        PaletteCommand(id: "enter", title: PickerStrings.openFolder, symbol: "chevron.right", effect: .deferred {
            .replace(self.page(for: state.moving(to: folder), back: state))
        })
    }

    func choose(_ urls: [URL]) -> PaletteCommand {
        PaletteCommand(id: "choose", title: PickerStrings.choose, symbol: "return", effect: .perform { self.finish(urls) })
    }
}
