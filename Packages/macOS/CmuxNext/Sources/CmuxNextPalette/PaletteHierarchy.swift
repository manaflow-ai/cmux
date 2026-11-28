import AppKit

/// A page over a tree (the folder and file picker): the page moves through
/// the tree in place instead of pushing one palette level per step, so a
/// deep folder never meets the navigation depth limit.
///
/// Keys (the palette's one key map, `PaletteKeyMap`): Tab, or Right with
/// the caret at the end of the query, enters the selected row; Left at the
/// start of the query, Backspace on an empty query or Cmd-Up goes up. A
/// query the page reads as a place (the picker's typed path) shows that
/// place's page. Each returns the page to show instead of the current one,
/// or nil when there is nowhere to go (Tab then opens the Actions menu,
/// Backspace pops the page as on any other page).
public struct PaletteHierarchy {
    public var enter: @MainActor (PaletteItem) -> PalettePageSpec?
    public var up: @MainActor () -> PalettePageSpec?
    public var jump: @MainActor (String) -> PalettePageSpec?

    public init(
        enter: @escaping @MainActor (PaletteItem) -> PalettePageSpec?,
        up: @escaping @MainActor () -> PalettePageSpec?,
        jump: @escaping @MainActor (String) -> PalettePageSpec? = { _ in nil }
    ) {
        self.enter = enter
        self.up = up
        self.jump = jump
    }
}

extension PaletteModel {
    /// The current page's tree navigation, if it has one.
    var currentHierarchy: PaletteHierarchy? {
        guard let current, case .list(let page) = current.kind else { return nil }
        return page.hierarchy
    }

    /// Whether Left and Right move through the current page's tree.
    public var currentPageIsHierarchical: Bool { currentHierarchy != nil }

    /// Tab or Right: enters the selected row. False when the page has no
    /// tree or the row does not enter.
    func enterSelectedRow() -> Bool {
        guard let hierarchy = currentHierarchy, let item = selectedItem, item.isEnabled,
              let page = hierarchy.enter(item) else { return false }
        replaceCurrentPage(with: page)
        return true
    }

    /// Left or Backspace on an empty query: goes up. False at the top.
    func leaveLevel() -> Bool {
        guard let hierarchy = currentHierarchy, let page = hierarchy.up() else { return false }
        replaceCurrentPage(with: page)
        return true
    }

    /// A click on footer segment `index`: its page in the current one's place.
    public func openCrumb(at index: Int) {
        guard let current, case .list(let page) = current.kind, page.crumbs.indices.contains(index),
              let next = page.crumbs[index].page() else { return }
        replaceCurrentPage(with: next)
    }

    /// A typed query the page reads as a place (a path): true when it moved.
    func jump(for text: String) -> Bool {
        guard let hierarchy = currentHierarchy, let page = hierarchy.jump(text) else { return false }
        replaceCurrentPage(with: page)
        return true
    }

    /// Shows `page` in the current level's place: same level, same chips,
    /// the page's `initialQuery`, and no rows until the new page's
    /// providers answer (Return waits for them, so it never runs a row of
    /// the page left). The page left is neither popped nor cancelled: the
    /// walk goes on.
    public func replaceCurrentPage(with page: PalettePageSpec) {
        guard let top = nav.top, let old = pages[top.id] else { return }
        if case .textInput = old.kind, nav.depth > 1 {
            // A text step (New Folder's name) was a detour from the page
            // below it: that level shows the new page, so the walk stays
            // one level deep.
            old.committed = true
            install(page, at: nav.levels[nav.depth - 2].id)
            send(.popTo(nav.depth - 2))
        } else {
            install(page, at: top.id)
        }
        send(.restart(query: page.initialQuery))
    }

    private func install(_ page: PalettePageSpec, at levelID: Int) {
        pages[levelID]?.cancel()
        pages[levelID]?.committed = false
        let state = PageState(kind: .list(page))
        state.levelID = levelID
        pages[levelID] = state
        // `mirror` shows the new page's title, placeholder and selection.
        shownLevelID = nil
        actionsMenu = nil
        hoveredRowID = nil
    }
}

extension PaletteController {
    /// Whether the field editor's caret sits at the end or the start of the
    /// query with nothing selected (Right or Left then has no text to move
    /// through).
    static func caret(in window: NSWindow?) -> (atStart: Bool, atEnd: Bool) {
        guard let editor = window?.firstResponder as? NSTextView else { return (true, true) }
        let selection = editor.selectedRange()
        guard selection.length == 0 else { return (false, false) }
        return (selection.location == 0, selection.location == (editor.string as NSString).length)
    }
}
