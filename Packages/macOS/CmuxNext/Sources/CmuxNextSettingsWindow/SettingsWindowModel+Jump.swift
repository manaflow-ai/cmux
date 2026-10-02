public import CmuxNextActions
public import CmuxNextDesign
public import CmuxNextSettings

/// Search that finds every row, card and button and jumps to it: opening a
/// result clears the query, shows its page (or scrolls the one page), and
/// highlights it for a moment (plans/cmux-next/settings-ia.md rule 3).
extension SettingsWindowModel {
    // MARK: Search

    /// Every entry matching `query`, in the order the results list shows
    /// them (empty without a query).
    public func searchEntries() -> [SettingsSearchEntry] {
        SettingsSearchIndex.matching(Self.words(query), in: SettingsSearchIndex.entries(registry: registry))
    }

    /// The results list: per section, the matching rows grouped as
    /// "Section › Group", then the section's matching cards and buttons.
    public func searchResultSections() -> [SettingsSearchResultSection] {
        let matches = searchEntries()
        return SettingsSection.allCases.compactMap { section in
            let entries = matches.filter { $0.section == section }
            guard !entries.isEmpty else { return nil }
            let groups = Self.grouped(entries.compactMap(\.descriptor)).map {
                SettingsGroup(title: "\(section.title) › \($0.title)", settings: $0.settings)
            }
            return SettingsSearchResultSection(section: section, groups: groups, others: entries.filter { $0.descriptor == nil })
        }
    }

    /// Matching schema rows in every section (empty without a query).
    public func searchResults() -> [SettingsGroup] {
        searchResultSections().flatMap(\.groups)
    }

    // MARK: Jump

    /// Opens `anchor`: clears the query, shows its section and scrolls to
    /// it; `highlight` lights it up until `endHighlight`.
    public func open(_ anchor: SettingsAnchor, highlight: Bool = true) {
        query = ""
        selection = anchor.section
        jumpSerial += 1
        jump = SettingsJump(anchor: anchor, serial: jumpSerial, highlights: highlight)
        highlighted = highlight ? anchor.id : nil
    }

    /// Return in the search field: opens the first result. False when
    /// nothing but shortcuts (or nothing) matches.
    @discardableResult
    public func openFirstResult() -> Bool {
        guard let first = searchEntries().first else { return false }
        open(first.anchor)
        return true
    }

    /// The deep link `openSettings setting:<key>`. False for an unknown key.
    @discardableResult
    public func open(setting key: String) -> Bool {
        guard let anchor = SettingsSearchIndex.anchor(for: key) else { return false }
        open(anchor)
        return true
    }

    /// A sidebar click or `openSettings section:`. Pages show the section;
    /// the one page scrolls to its header.
    public func select(_ section: SettingsSection, layout: SettingsWindowLayout) {
        switch layout {
        case .pages:
            query = ""
            selection = section
        case .onePage:
            open(.header(section), highlight: false)
        }
    }

    /// Ends `jump`'s highlight; a newer jump keeps its own.
    public func endHighlight(_ jump: SettingsJump) {
        guard self.jump?.serial == jump.serial else { return }
        highlighted = nil
    }

    /// How the current highlight goes away, for the live (or pinned)
    /// speed and Reduce Motion.
    public var highlightPlan: SettingsHighlightPlan {
        SettingsHighlightPlan.make(policy: motionPolicyOverride ?? Motion.policy)
    }

    // MARK: One page

    /// The one page's search filter; nil without a query.
    public func pageFilter() -> SettingsPageFilter? {
        guard !Self.words(query).isEmpty else { return nil }
        return SettingsPageFilter(matches: searchEntries(), shortcutsMatch: !shortcutSections().isEmpty)
    }

    /// The sections the one page shows, in order.
    public func pageSections(_ filter: SettingsPageFilter?) -> [SettingsSection] {
        filter?.filter(SettingsSection.allCases) ?? SettingsSection.allCases
    }

    /// The section's groups, with only matching rows under a filter.
    public func groups(in section: SettingsSection, filter: SettingsPageFilter?) -> [SettingsGroup] {
        let all = groups(in: section)
        return filter?.filter(all) ?? all
    }

    /// The section's action buttons the registry knows, matching ones only
    /// under a filter.
    public func actions(in section: SettingsSection, filter: SettingsPageFilter?) -> [ActionID] {
        SettingsSchema.actions(in: section).filter { id in
            actionTitle(id) != nil && (filter?.shows(SettingsAnchor.action(id, in: section).id) ?? true)
        }
    }

    /// Whether a card shows under `filter`.
    public func shows(_ card: SettingsCardID, filter: SettingsPageFilter?) -> Bool {
        filter?.shows(card.anchorID) ?? true
    }
}
