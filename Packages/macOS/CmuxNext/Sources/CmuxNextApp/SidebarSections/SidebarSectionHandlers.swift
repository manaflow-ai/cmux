import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSidebar

/// Sidebar section actions (plans/cmux-next/sidebar-sections.md 6): each
/// turns into one layout op for `SidebarLayoutService`. Right-click menus
/// pass the item or section as the target; the palette asks for it; the CLI
/// names it (`sidebar-section:sec_…`, `sidebar-item:itm_…` or a built-in
/// name such as `sidebar-item:home`).
enum SidebarSectionHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let layout = context.services.sidebarLayout
        // Item adds and removes are undo steps (P4) through the one pin path,
        // named as the menu showed them.
        func bind(_ id: ActionID, undoable: Bool = false, unavailable: @escaping @MainActor () -> String? = { nil },
                  _ run: @escaping @MainActor (ActionInvocation, SidebarLayoutDocument) throws -> SidebarLayoutOp?) {
            registry.bind(id, unavailable: { layout.unavailableReason ?? unavailable() }, invoke: { [weak registry] invocation in
                do {
                    guard let op = try run(invocation, layout.document) else { return }
                    guard undoable, let registry else { return try layout.send(op) }
                    let title = registry.action(for: id)?.targetTitle?(invocation) ?? registry.descriptor(for: id)?.title ?? ""
                    try PinCommands(context: context).sendLayout(op, title: title, origin: invocation.origin)
                } catch {
                    registry?.refuse(String(describing: error))
                }
            })
        }
        let home = SidebarLayoutDocument.homeRef
        bind("sidebar.home.add", undoable: true, unavailable: { layout.document.firstItem(with: home) == nil ? nil : SidebarSectionStrings.homeAlreadyShown }) { _, doc in
            SidebarLayoutPlanner.add(home, in: doc)
        }
        bind("sidebar.home.remove", undoable: true, unavailable: { layout.document.firstItem(with: home) != nil ? nil : SidebarSectionStrings.homeNotShown }) { _, doc in
            SidebarLayoutPlanner.remove(home, in: doc)
        }
        bind("sidebar.item.add", undoable: true) { invocation, doc in
            guard let name = invocation["item"]?.stringValue?.trimmingCharacters(in: .whitespaces) else {
                throw ActionFailure(message: SidebarSectionStrings.noSuchItem)
            }
            // Any workspace or app goes in the top rows ("Add to Top", P1), or the named section.
            if let ref = try SidebarSectionResolve.workspaceOrApp(name, machines: context.services.machines) {
                // A workspace's name is stored with its item, for when it is closed.
                let label = WorkspaceLayoutRefs(machines: context.services.machines).workspace(for: ref)?.0.displayName
                if let sectionName = invocation["section"]?.stringValue, !sectionName.isEmpty {
                    let section = try SidebarSectionResolve.section(sectionName, in: doc)
                    return .itemAdd(LayoutItem(id: .mint(), ref: ref, label: label), section: section.id, index: Int.max)
                }
                guard let op = doc.addToTopOp(ref, label: label) else { throw ActionFailure(message: SidebarSectionStrings.alreadyOnTop) }
                return op
            }
            guard let builtIn = SidebarBuiltIn(rawValue: name) else { throw ActionFailure(message: SidebarSectionStrings.noSuchItem) }
            // Home and the App Store are apps now (R63/R64).
            let ref = SidebarLayoutDocument.firstPartyApps[builtIn].map(LayoutItemRef.app) ?? LayoutItemRef.builtIn(builtIn)
            if let sectionName = invocation["section"]?.stringValue, !sectionName.isEmpty {
                let section = try SidebarSectionResolve.section(sectionName, in: doc)
                return .itemAdd(LayoutItem(id: .mint(), ref: ref), section: section.id, index: Int.max)
            }
            // The account shows as its avatar (no label) by default.
            return SidebarLayoutPlanner.add(ref, to: builtIn == .settings || builtIn == .account ? .bottom : .top, in: doc,
                                            showsLabel: builtIn != .account)
        }
        bind("sidebar.item.remove", undoable: true) { invocation, doc in
            .itemRemove(try SidebarSectionResolve.item(invocation.target, in: doc).id)
        }
        bind("sidebar.item.removeEverywhere", undoable: true) { invocation, doc in
            .itemRemoveRef(try SidebarSectionResolve.item(invocation.target, in: doc).ref)
        }
        // On a tile the menu reads Unpin Workspace; on a top row, Remove from Top.
        ActionTargetTitles.set("sidebar.item.remove", in: registry) { invocation in
            let doc = layout.document
            guard let item = try? SidebarSectionResolve.item(invocation.target, in: doc), let (s, _) = doc.locate(item.id) else { return nil }
            if doc.sections[s].id == SidebarLayoutDocument.pinnedSectionID, item.ref.kind == LayoutItemRef.workspaceKind {
                return PinStrings.unpinWorkspace
            }
            return doc.sections[s].region == .top ? PinStrings.removeFromTop : nil
        }
        // Hide is app-level state owned by the app platform (D55): the
        // sidebar forwards to its `app.hide` action and changes no layout.
        registry.bind("sidebar.item.hideApp", run: { [weak registry] invocation in
            guard let app = try SidebarSectionResolve.owningApp(invocation.target, in: layout.document) else {
                throw ActionFailure(message: SidebarSectionStrings.notAnApp)
            }
            guard let registry, registry.action(for: "app.hide") != nil else { throw ActionFailure.needsAppCapability("app.hide") }
            _ = registry.perform("app.hide", invocation: ActionInvocation(arguments: ["app": .string(app)], origin: invocation.origin))
        })
        bind("sidebar.section.add") { invocation, _ in
            let region = invocation["region"]?.stringValue.flatMap(SidebarRegion.init(rawValue:)) ?? .top
            let title = invocation["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return .sectionAdd(LayoutSection(id: .mint(), title: title ?? SidebarSectionStrings.untitledSection, region: region, look: .list),
                               index: Int.max)
        }
        bind("sidebar.section.rename") { invocation, doc in
            let section = try SidebarSectionResolve.section(invocation.target, in: doc)
            let title = invocation["title"]?.stringValue ?? ""
            return .sectionUpdate(section.id, SectionPatch(title: title.isEmpty ? .clear : .set(title)))
        }
        let moves: [(ActionID, SidebarRegion)] = [("sidebar.section.moveToTop", .top), ("sidebar.section.moveToScrolling", .middle),
                                                  ("sidebar.section.moveToBottom", .bottom)]
        for (id, region) in moves {
            bind(id) { invocation, doc in
                let section = try SidebarSectionResolve.section(invocation.target, in: doc)
                return .sectionMove(section.id, region: region, index: region == .bottom ? 0 : Int.max)
            }
        }
        let looks: [(ActionID, SectionLook)] = [("sidebar.section.useBuiltInLook", .builtIn), ("sidebar.section.useListLook", .list)]
        for (id, look) in looks {
            bind(id) { invocation, doc in
                .sectionUpdate(try SidebarSectionResolve.section(invocation.target, in: doc).id, SectionPatch(look: look))
            }
        }
        let layouts: [(ActionID, SectionArrangement.Layout)] = [("sidebar.section.layoutList", .list),
                                                                ("sidebar.section.layoutInline", .inline), ("sidebar.section.layoutGrid", .grid)]
        for (id, kind) in layouts {
            bind(id) { invocation, doc in
                .sectionUpdate(try SidebarSectionResolve.section(invocation.target, in: doc).id, SectionPatch(layout: kind))
            }
        }
        bind("sidebar.section.setAlignment") { invocation, doc in
            let section = try SidebarSectionResolve.section(invocation.target, in: doc)
            let align = invocation["align"]?.stringValue.flatMap(SectionArrangement.Alignment.init(rawValue:)) ?? .leading
            return .sectionUpdate(section.id, SectionPatch(align: align))
        }
        bind("sidebar.section.setGap") { invocation, doc in
            let section = try SidebarSectionResolve.section(invocation.target, in: doc)
            return .sectionUpdate(section.id, SectionPatch(gap: invocation["gap"]?.intValue.map(OptionalUpdate.set) ?? .clear))
        }
        bind("sidebar.section.setColumns") { invocation, doc in
            let section = try SidebarSectionResolve.section(invocation.target, in: doc)
            let columns = invocation["columns"]?.intValue ?? 0
            return .sectionUpdate(section.id, SectionPatch(columns: columns == 0 ? .clear : .set(columns)))
        }
        bind("sidebar.item.toggleLabel") { invocation, doc in
            let item = try SidebarSectionResolve.item(invocation.target, in: doc)
            // Labels can be hidden only on a line (inline arrangement).
            guard let (s, _) = doc.locate(item.id), doc.sections[s].arrangement.layout == .inline else {
                throw ActionFailure(message: SidebarSectionStrings.labelsOnlyOnALine)
            }
            return .itemUpdate(item.id, showsLabel: !item.showsLabel)
        }
        bind("sidebar.section.toggleTitle") { invocation, doc in
            let section = try SidebarSectionResolve.section(invocation.target, in: doc)
            return .sectionUpdate(section.id, SectionPatch(showsTitle: !section.showsTitle))
        }
        bind("sidebar.section.toggleSpaceScope") { [weak services = context.services] invocation, doc in
            let section = try SidebarSectionResolve.section(invocation.target, in: doc)
            guard section.room == nil else { return .sectionUpdate(section.id, SectionPatch(room: .clear)) }
            let room = services?.windows.active?.state.profileID.rawValue
            return room.map { .sectionUpdate(section.id, SectionPatch(room: .set($0))) }
        }
        bind("sidebar.section.setMaxRows") { invocation, doc in
            let section = try SidebarSectionResolve.section(invocation.target, in: doc)
            let rows = invocation["rows"]?.intValue ?? 0
            return .sectionUpdate(section.id, SectionPatch(maxRows: rows == 0 ? .clear : .set(rows)))
        }
        bind("sidebar.section.remove") { invocation, doc in
            .sectionRemove(try SidebarSectionResolve.section(invocation.target, in: doc).id)
        }
        bind("sidebar.layout.reset") { _, _ in .reset }
        // Collapse is this window's view state: no layout op.
        registry.bind("sidebar.section.toggleCollapsed", run: { [weak services = context.services] invocation in
            guard let model = services?.windows.active?.sidebar.model else { return }
            let section = try SidebarSectionResolve.section(invocation.target, in: model.layout)
            model.apply(.toggleLayoutSection(section.id))
        })
    }
}

/// Resolves a section or item named by a target or an argument.
enum SidebarSectionResolve {
    static func section(_ target: ActionTargetRef?, in doc: SidebarLayoutDocument) throws -> LayoutSection {
        guard let target, target.kind == .sidebarSection else { throw ActionFailure(message: SidebarSectionStrings.noSuchSection) }
        return try section(target.id, in: doc)
    }

    /// By id, else by exact title.
    static func section(_ name: String, in doc: SidebarLayoutDocument) throws -> LayoutSection {
        if let section = doc.section(LayoutSectionID(name)) ?? doc.sections.first(where: { $0.title == name }) { return section }
        throw ActionFailure(message: SidebarSectionStrings.noSuchSection)
    }

    /// The app an item or section target belongs to (an app item's app, an
    /// app section's contribution owner), or nil.
    static func owningApp(_ target: ActionTargetRef?, in doc: SidebarLayoutDocument) throws -> String? {
        switch target?.kind {
        case .sidebarSection?: try section(target, in: doc).owningAppID
        default: try item(target, in: doc).owningAppID
        }
    }

    /// The ref `workspace:<id>` or `app:<publisher>/<name>` names, nil for
    /// another text. A workspace is named by its qualified `<session>:ws_…`
    /// id, its `ws_…` id or its sidebar id, and must be open.
    @MainActor static func workspaceOrApp(_ text: String, machines: MachineRegistry) throws -> LayoutItemRef? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let kind = text[..<colon], value = String(text[text.index(after: colon)...])
        switch kind {
        case "app":
            guard value.contains("/"), !value.hasPrefix("/"), !value.hasSuffix("/") else { throw ActionFailure(message: SidebarSectionStrings.noSuchItem) }
            return .app(value)
        case "workspace":
            let refs = WorkspaceLayoutRefs(machines: machines)
            if refs.workspace(for: .workspace(value)) != nil { return .workspace(value) }
            let found = machines.allWorkspaces.first { $0.0.id == value || $0.0.resourceID?.rawValue == value }
            guard let found, let ref = refs.ref(for: found.0, on: found.1) else { throw ActionFailure(message: SidebarSectionStrings.noSuchItem) }
            return ref
        default:
            return nil
        }
    }

    /// By item id, else by built-in name (`home`).
    static func item(_ target: ActionTargetRef?, in doc: SidebarLayoutDocument) throws -> LayoutItem {
        guard let target, target.kind == .sidebarItem else { throw ActionFailure(message: SidebarSectionStrings.noSuchItem) }
        if let item = doc.item(LayoutItemID(target.id)) { return item }
        if let builtIn = SidebarBuiltIn(rawValue: target.id) {
            // Home and the App Store are app items now (R63/R64); their names still name them.
            let ref = SidebarLayoutDocument.firstPartyApps[builtIn].map(LayoutItemRef.app) ?? .builtIn(builtIn)
            if let item = doc.firstItem(with: ref) { return item }
        }
        throw ActionFailure(message: SidebarSectionStrings.noSuchItem)
    }
}
