import Foundation

/// The pure reducer of the section layout: `(document, op) -> document or
/// reject`, checking invariants L1-L6 (plans/cmux-next/sidebar-sections.md
/// 4). The store runs the same rules; clients run it to overlay pending
/// intents on the confirmed mirror.
public nonisolated enum SidebarLayoutReducer {
    public static let maxSections = 32
    public static let maxItems = 200
    public static let maxTitleLength = 80
    public static let maxRowsRange = 1...50

    /// The new document, or the reject. A change bumps `revision` by one;
    /// a no-op returns the document unchanged.
    public static func reduce(_ document: SidebarLayoutDocument, _ op: SidebarLayoutOp) -> Result<SidebarLayoutDocument, SidebarLayoutReject> {
        var sections = document.sections
        do {
            switch op {
            case let .sectionAdd(section, index):
                try add(section, at: index, to: &sections)
            case let .sectionUpdate(id, patch):
                try update(id, patch, in: &sections)
            case let .sectionMove(id, region, index):
                try moveSection(id, to: region, at: index, in: &sections)
            case let .sectionRemove(id):
                guard let s = sections.firstIndex(where: { $0.id == id }) else { throw SidebarLayoutReject.unknownSection }
                guard sections[s].content != .workspaces else { throw SidebarLayoutReject.workspacesRequired }
                sections.remove(at: s)
            case let .itemAdd(item, section, index):
                try addItem(item, to: section, at: index, in: &sections)
            case let .itemMove(id, section, index):
                try moveItem(id, to: section, at: index, in: &sections)
            case let .itemRemove(id):
                guard let (s, i) = locate(id, in: sections) else { throw SidebarLayoutReject.unknownItem }
                sections[s].items.remove(at: i)
            case let .itemUpdate(id, showsLabel):
                guard let (s, i) = locate(id, in: sections) else { throw SidebarLayoutReject.unknownItem }
                sections[s].items[i].showsLabel = showsLabel
            case .reset:
                sections = SidebarLayoutDocument.defaults.sections
            }
        } catch let reject as SidebarLayoutReject {
            return .failure(reject)
        } catch {
            preconditionFailure("SidebarLayoutReducer throws only SidebarLayoutReject")
        }
        guard sections != document.sections else { return .success(document) }
        return .success(SidebarLayoutDocument(revision: document.revision + 1, sections: sections))
    }

    // MARK: Sections

    private static func add(_ section: LayoutSection, at index: Int, to sections: inout [LayoutSection]) throws {
        guard sections.count < maxSections else { throw SidebarLayoutReject.tooMany }
        guard !sections.contains(where: { $0.id == section.id }) else { throw SidebarLayoutReject.duplicateID }
        switch section.content {
        case .workspaces:
            // L1: exactly one, and it holds no items.
            throw SidebarLayoutReject.workspacesRequired
        case .items:
            break
        }
        try validate(title: section.title)
        try validate(maxRows: section.maxRows)
        guard section.arrangement.isValid else { throw SidebarLayoutReject.invalidArrangement }
        let existing = Set(sections.flatMap { $0.items.map(\.id) })
        let newIDs = section.items.map(\.id)
        guard Set(newIDs).count == newIDs.count, existing.isDisjoint(with: newIDs) else { throw SidebarLayoutReject.duplicateID }
        guard Set(section.items.map(\.ref)).count == section.items.count else { throw SidebarLayoutReject.duplicateRef }
        guard existing.count + newIDs.count <= maxItems else { throw SidebarLayoutReject.tooMany }
        sections.insert(section, at: insertionIndex(region: section.region, index: index, in: sections))
    }

    private static func update(_ id: LayoutSectionID, _ patch: SectionPatch, in sections: inout [LayoutSection]) throws {
        guard let s = sections.firstIndex(where: { $0.id == id }) else { throw SidebarLayoutReject.unknownSection }
        if let title = patch.title {
            try validate(title: title.value)
            sections[s].title = title.value
        }
        if let look = patch.look { sections[s].look = look }
        if let showsTitle = patch.showsTitle { sections[s].showsTitle = showsTitle }
        var arrangement = sections[s].arrangement
        if let layout = patch.layout { arrangement.layout = layout }
        if let align = patch.align { arrangement.align = align }
        if let gap = patch.gap { arrangement.gap = gap.value }
        if let columns = patch.columns { arrangement.columns = columns.value }
        guard arrangement.isValid else { throw SidebarLayoutReject.invalidArrangement }
        sections[s].arrangement = arrangement
        if let room = patch.room {
            // L1: the workspace list shows in every room.
            if sections[s].content == .workspaces, room.value != nil { throw SidebarLayoutReject.workspacesRequired }
            sections[s].room = room.value
        }
        if let maxRows = patch.maxRows {
            try validate(maxRows: maxRows.value)
            sections[s].maxRows = maxRows.value
        }
    }

    private static func moveSection(_ id: LayoutSectionID, to region: SidebarRegion, at index: Int, in sections: inout [LayoutSection]) throws {
        guard let s = sections.firstIndex(where: { $0.id == id }) else { throw SidebarLayoutReject.unknownSection }
        var section = sections.remove(at: s)
        section.region = region
        sections.insert(section, at: insertionIndex(region: region, index: index, in: sections))
    }

    /// Document index for the `index`-th slot (clamped) among `region`'s
    /// sections: before the section now at that slot, or after the
    /// region's last section, or (empty region) after every section of an
    /// earlier region.
    private static func insertionIndex(region: SidebarRegion, index: Int, in sections: [LayoutSection]) -> Int {
        let inRegion = sections.indices.filter { sections[$0].region == region }
        if inRegion.isEmpty {
            let order = SidebarRegion.allCases
            let rank = order.firstIndex(of: region) ?? 0
            return sections.lastIndex { (order.firstIndex(of: $0.region) ?? 0) <= rank }.map { $0 + 1 } ?? 0
        }
        let slot = min(max(index, 0), inRegion.count)
        return slot == inRegion.count ? inRegion[inRegion.count - 1] + 1 : inRegion[slot]
    }

    // MARK: Items

    private static func addItem(_ item: LayoutItem, to id: LayoutSectionID, at index: Int, in sections: inout [LayoutSection]) throws {
        guard let s = sections.firstIndex(where: { $0.id == id }) else { throw SidebarLayoutReject.unknownSection }
        guard sections[s].content == .items else { throw SidebarLayoutReject.workspacesRequired }
        guard locate(item.id, in: sections) == nil else { throw SidebarLayoutReject.duplicateID }
        // L3: pinning a reference twice into one section is a no-op.
        if sections[s].items.contains(where: { $0.ref == item.ref }) { return }
        guard sections.reduce(0, { $0 + $1.items.count }) < maxItems else { throw SidebarLayoutReject.tooMany }
        let slot = min(max(index, 0), sections[s].items.count)
        sections[s].items.insert(item, at: slot)
    }

    private static func moveItem(_ id: LayoutItemID, to target: LayoutSectionID, at index: Int, in sections: inout [LayoutSection]) throws {
        guard let (s, i) = locate(id, in: sections) else { throw SidebarLayoutReject.unknownItem }
        guard let t = sections.firstIndex(where: { $0.id == target }) else { throw SidebarLayoutReject.unknownSection }
        guard sections[t].content == .items else { throw SidebarLayoutReject.workspacesRequired }
        let item = sections[s].items[i]
        if t != s, sections[t].items.contains(where: { $0.ref == item.ref }) { throw SidebarLayoutReject.duplicateRef }
        sections[s].items.remove(at: i)
        let slot = min(max(index, 0), sections[t].items.count)
        sections[t].items.insert(item, at: slot)
    }

    static func locate(_ id: LayoutItemID, in sections: [LayoutSection]) -> (Int, Int)? {
        for (s, section) in sections.enumerated() {
            if let i = section.items.firstIndex(where: { $0.id == id }) { return (s, i) }
        }
        return nil
    }

    // MARK: Validation

    private static func validate(title: String?) throws {
        guard let title else { return }
        guard !title.isEmpty, title.count <= maxTitleLength else { throw SidebarLayoutReject.invalidTitle }
    }

    private static func validate(maxRows: Int?) throws {
        guard let maxRows else { return }
        guard maxRowsRange.contains(maxRows) else { throw SidebarLayoutReject.invalidMaxRows }
    }
}
