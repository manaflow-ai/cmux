import CmuxNextActions
import CmuxNextSidebar

/// Sidebar section actions (plans/cmux-next/sidebar-sections.md 6): each
/// turns into one layout op for `SidebarLayoutService`. Right-click menus
/// pass the item or section as the target; the palette asks for it; the CLI
/// names it (`sidebar-section:sec_…`, `sidebar-item:itm_…` or a built-in
/// name such as `sidebar-item:home`).
enum SidebarSectionHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let layout = context.services.sidebarLayout
        func bind(_ id: ActionID, unavailable: @escaping @MainActor () -> String? = { nil },
                  _ run: @escaping @MainActor (ActionInvocation, SidebarLayoutDocument) throws -> SidebarLayoutOp?) {
            registry.bind(id, unavailable: { layout.unavailableReason ?? unavailable() }, invoke: { [weak registry] invocation in
                do {
                    if let op = try run(invocation, layout.document) { try layout.send(op) }
                } catch {
                    registry?.refuse(String(describing: error))
                }
            })
        }
        let home = LayoutItemRef.builtIn(.home)
        bind("sidebar.home.add", unavailable: { layout.document.firstItem(with: home) == nil ? nil : SidebarSectionStrings.homeAlreadyShown }) { _, doc in
            SidebarLayoutPlanner.add(home, in: doc)
        }
        bind("sidebar.home.remove", unavailable: { layout.document.firstItem(with: home) != nil ? nil : SidebarSectionStrings.homeNotShown }) { _, doc in
            SidebarLayoutPlanner.remove(home, in: doc)
        }
        bind("sidebar.item.add") { invocation, doc in
            guard let name = invocation["item"]?.stringValue, let builtIn = SidebarBuiltIn(rawValue: name) else {
                throw ActionFailure(message: SidebarSectionStrings.noSuchItem)
            }
            let ref = LayoutItemRef.builtIn(builtIn)
            if let sectionName = invocation["section"]?.stringValue, !sectionName.isEmpty {
                let section = try SidebarSectionResolve.section(sectionName, in: doc)
                return .itemAdd(LayoutItem(id: .mint(), ref: ref), section: section.id, index: Int.max)
            }
            // The account shows as its avatar (no label) by default.
            return SidebarLayoutPlanner.add(ref, to: builtIn == .settings || builtIn == .account ? .bottom : .top, in: doc,
                                            showsLabel: builtIn != .account)
        }
        bind("sidebar.item.remove") { invocation, doc in
            .itemRemove(try SidebarSectionResolve.item(invocation.target, in: doc).id)
        }
        bind("sidebar.item.removeEverywhere") { invocation, doc in
            .itemRemoveRef(try SidebarSectionResolve.item(invocation.target, in: doc).ref)
        }
        // Hide is app-level state owned by the app platform (D55): the
        // sidebar forwards to its `app.hide` action and changes no layout.
        registry.bind("sidebar.item.hideApp", run: { [weak registry] invocation in
            let item = try SidebarSectionResolve.item(invocation.target, in: layout.document)
            guard item.ref.kind == LayoutItemRef.appKind else { throw ActionFailure(message: SidebarSectionStrings.notAnApp) }
            guard let registry, registry.action(for: "app.hide") != nil else { throw ActionFailure.needsAppCapability("app.hide") }
            _ = registry.perform("app.hide", invocation: ActionInvocation(arguments: ["app": .string(item.ref.value)], origin: invocation.origin))
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
        bind("sidebar.section.toggleRoomScope") { [weak services = context.services] invocation, doc in
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

    /// By item id, else by built-in name (`home`).
    static func item(_ target: ActionTargetRef?, in doc: SidebarLayoutDocument) throws -> LayoutItem {
        guard let target, target.kind == .sidebarItem else { throw ActionFailure(message: SidebarSectionStrings.noSuchItem) }
        if let item = doc.item(LayoutItemID(target.id)) { return item }
        if let builtIn = SidebarBuiltIn(rawValue: target.id), let item = doc.firstItem(with: .builtIn(builtIn)) { return item }
        throw ActionFailure(message: SidebarSectionStrings.noSuchItem)
    }
}
