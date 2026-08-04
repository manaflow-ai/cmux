import AppKit
import Combine
import CmuxCommandPalette
import CmuxFoundation
import SwiftUI

extension Notification.Name {
    /// Posted by the `searchTabs` keyboard shortcut to focus the sidebar
    /// tab-search field. The `object` is the target `NSWindow` so only that
    /// window's field responds.
    static let cmuxSidebarTabSearchFocusRequested = Notification.Name("cmux.sidebarTabSearchFocusRequested")
}

/// Compact tab-name search pinned at the top-left of the workspace sidebar.
///
/// Typing filters every workspace (vertical tab) and surface (horizontal tab)
/// by name and shows a dropdown of hits grouped into a Workspaces section and a
/// Tabs section. Arrow keys move the selection, Return jumps to the selected
/// hit, Esc clears, and clicking a row focuses it. It reuses the Cmd-P switcher
/// corpus (via `entriesProvider`) so ranking, keywords, and the focus action
/// match the command palette.
///
/// The dropdown is an eager `VStack` of immutable ``SidebarTabSearchResult``
/// value rows (no `LazyVStack`, no store references), so it stays clear of the
/// sidebar lazy-layout snapshot boundary (CLAUDE.md / issue #2586). The text
/// field is a native `NSTextField` so ↑/↓/Return/Esc reach the dropdown
/// selection handlers instead of the field editor (the same reason the command
/// palette uses a native field).
struct SidebarTabSearchView: View {
    /// Supplies the current switcher corpus (workspaces + surfaces) with
    /// ready-made navigation actions. Backed by
    /// `ContentView.commandPaletteSwitcherEntries(includeSurfaces:)`.
    let entriesProvider: () -> [CommandPaletteCommand]
    /// Cheap fingerprint of the switcher corpus (names/metadata hash, no fuzzy
    /// preparation). Checked on every keystroke so the session cache rebuilds
    /// when workspaces or surfaces change mid-search instead of serving stale
    /// rows. Backed by `ContentView.commandPaletteSwitcherEntriesFingerprint`.
    var fingerprintProvider: () -> Int = { 0 }
    /// This sidebar's window, used to accept only the `searchTabs` focus request
    /// routed to this window (the notification is posted per target window).
    var focusTargetWindow: NSWindow?
    /// Space left below the field inside the sidebar. The dropdown never grows
    /// past it, so its lower rows can't land in clipped-away space that even
    /// scrolling can't reveal. Zero means "not measured yet".
    var availableDropdownHeight: CGFloat = 0

    @State private var query: String = ""
    @State private var results: [SidebarTabSearchResult] = []
    @State private var actionsById: [String: () -> Void] = [:]
    /// Index into ``orderedResults`` (visual order) of the highlighted row.
    @State private var selectedIndex: Int = 0
    /// Bumped by the focus shortcut; the text field focuses once per new value.
    @State private var focusToken: Int = 0
    /// Corpus + ranking index, built once per search session (first keystroke)
    /// and reused for every later keystroke; dropped when the search clears.
    /// Building it walks every window/workspace/surface, so rebuilding per
    /// keystroke would be needless work.
    @State private var cachedIndex: SidebarTabSearchIndex?
    @State private var cachedActions: [String: () -> Void] = [:]
    /// Fingerprint the cached corpus was built from; a mismatch on the next
    /// keystroke forces a rebuild.
    @State private var cachedFingerprint: Int?

    private static let resultLimit = 40
    private static let workspaceIdPrefix = "switcher.workspace."
    /// Approximate rendered height of one result row (title + subtitle + padding).
    private static let estimatedRowHeight: CGFloat = 40
    /// Approximate rendered height of one section header.
    private static let sectionHeaderHeight: CGFloat = 22
    /// The dropdown's own top/bottom padding.
    private static let dropdownVerticalPadding: CGFloat = 8
    /// Cap beyond which the dropdown scrolls instead of growing further.
    private static let maxDropdownHeight: CGFloat = 320

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var workspaceResults: [SidebarTabSearchResult] {
        results.filter { $0.kind == .workspace }
    }

    private var tabResults: [SidebarTabSearchResult] {
        results.filter { $0.kind == .tab }
    }

    /// Results in the order they appear in the dropdown (Workspaces then Tabs),
    /// which is the order ↑/↓ navigate.
    private var orderedResults: [SidebarTabSearchResult] {
        workspaceResults + tabResults
    }

    private var selectedResultID: String? {
        guard orderedResults.indices.contains(selectedIndex) else { return orderedResults.first?.id }
        return orderedResults[selectedIndex].id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchField
            if isSearching {
                resultsDropdown
            }
        }
        // Esc also clears when focus sits on the dropdown rather than the field.
        .onExitCommand(perform: dismiss)
        // The `searchTabs` shortcut (⌥⌘P) focuses the field — but only in the
        // window the request was routed to. A monotonic token (rather than a
        // sustained "isFocused" flag) avoids re-focusing on every render.
        .onReceive(NotificationCenter.default.publisher(for: .cmuxSidebarTabSearchFocusRequested)) { notification in
            guard let target = notification.object as? NSWindow, target === focusTargetWindow else { return }
            focusToken &+= 1
        }
        // Ranking is cheap and synchronous, so results always reflect the
        // current query with no debounce timer (no stale hits, no Task.sleep).
        .onChange(of: query) { _, _ in
            refreshResults()
        }
    }

    /// Height needed to show all current results, so the dropdown shrinks to
    /// fit a few hits instead of always reserving the full maximum. Scrolls
    /// only once the estimate exceeds `maxDropdownHeight`.
    private var dropdownContentHeight: CGFloat {
        guard !results.isEmpty else { return 0 }
        let sectionCount = (workspaceResults.isEmpty ? 0 : 1) + (tabResults.isEmpty ? 0 : 1)
        let rowsHeight = CGFloat(results.count) * Self.estimatedRowHeight
        let headersHeight = CGFloat(sectionCount) * Self.sectionHeaderHeight
        return rowsHeight + headersHeight + Self.dropdownVerticalPadding
    }

    /// The dropdown's rendered height: its content, capped by the fixed maximum
    /// and by whatever room the sidebar actually leaves below the field.
    private var dropdownHeight: CGFloat {
        var cap = Self.maxDropdownHeight
        if availableDropdownHeight > 0 {
            cap = min(cap, availableDropdownHeight)
        }
        return min(dropdownContentHeight, cap)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .cmuxFont(size: 11, weight: .medium)
                .foregroundColor(.secondary)
            SidebarTabSearchTextField(
                text: $query,
                focusToken: focusToken,
                placeholder: String(
                    localized: "sidebar.tabSearch.placeholder",
                    defaultValue: "Search tabs"
                ),
                onSubmit: runSelectedResult,
                onEscape: dismiss,
                onMoveSelection: moveSelection
            )
            .frame(maxWidth: .infinity)
            if !query.isEmpty {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        localized: "sidebar.tabSearch.clear",
                        defaultValue: "Clear tab search"
                    )
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var resultsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text(
                    String(
                        localized: "sidebar.tabSearch.noMatches",
                        defaultValue: "No matching tabs"
                    )
                )
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            resultSection(
                                title: String(
                                    localized: "sidebar.tabSearch.section.workspaces",
                                    defaultValue: "Workspaces"
                                ),
                                rows: workspaceResults
                            )
                            resultSection(
                                title: String(
                                    localized: "sidebar.tabSearch.section.tabs",
                                    defaultValue: "Tabs"
                                ),
                                rows: tabResults
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: dropdownHeight)
                    // Keep the arrow-selected row visible while scrolling.
                    .onChange(of: selectedIndex) { _, _ in
                        guard let id = selectedResultID else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }

    @ViewBuilder
    private func resultSection(title: String, rows: [SidebarTabSearchResult]) -> some View {
        if !rows.isEmpty {
            Text(title.uppercased())
                .cmuxFont(size: 10, weight: .semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(rows) { row in
                SidebarTabSearchResultRow(
                    result: row,
                    isSelected: row.id == selectedResultID,
                    onSelect: { run(row) }
                )
                .id(row.id)
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !orderedResults.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), orderedResults.count - 1)
    }

    /// Ranks the current query against the session corpus. Ranking is cheap and
    /// synchronous; the corpus itself is built once per search session. Runs
    /// from `.onChange(of: query)`, never from `body`.
    private func refreshResults() {
        let searchQuery = trimmedQuery
        guard !searchQuery.isEmpty else {
            results = []
            actionsById = [:]
            selectedIndex = 0
            cachedIndex = nil
            cachedActions = [:]
            cachedFingerprint = nil
            return
        }

        let fingerprint = fingerprintProvider()
        let index: SidebarTabSearchIndex
        if let cachedIndex, cachedFingerprint == fingerprint {
            index = cachedIndex
        } else {
            let built = buildCorpus()
            cachedIndex = built.index
            cachedActions = built.actions
            cachedFingerprint = fingerprint
            index = built.index
        }

        results = index.rankedResults(matching: searchQuery, limit: Self.resultLimit)
        actionsById = cachedActions
        selectedIndex = 0
    }

    /// Walks every window/workspace/surface to build the searchable corpus and
    /// its ranking index. Expensive relative to ranking, hence the session cache.
    private func buildCorpus() -> (index: SidebarTabSearchIndex, actions: [String: () -> Void]) {
        let commands = entriesProvider()
        var actions: [String: () -> Void] = [:]
        actions.reserveCapacity(commands.count)
        let candidates: [SidebarTabSearchCandidate] = commands.map { command in
            actions[command.id] = command.action
            return SidebarTabSearchCandidate(
                id: command.id,
                rank: command.rank,
                title: command.title,
                subtitle: command.subtitle,
                kindLabel: command.kindLabel,
                keywords: command.keywords,
                // The switcher ids are `switcher.workspace.*` / `switcher.surface.*`;
                // anything that is not a workspace row is a tab (surface) row.
                kind: command.id.hasPrefix(Self.workspaceIdPrefix) ? .workspace : .tab
            )
        }
        return (SidebarTabSearchIndex(candidates: candidates), actions)
    }

    /// Runs the highlighted hit. Ranking is synchronous, so `results` always
    /// reflects the current query: an out-of-range selection means there simply
    /// are no matches, and there is nothing to fall back to.
    private func runSelectedResult() {
        guard orderedResults.indices.contains(selectedIndex) else { return }
        run(orderedResults[selectedIndex])
    }

    private func run(_ result: SidebarTabSearchResult) {
        // The action focuses the target surface, so no focus restore here.
        actionsById[result.id]?()
        clear()
    }

    /// Dismiss without navigating (Esc / clear button): drop the search and
    /// return keyboard focus to the terminal, so the window isn't left with no
    /// first responder (mirrors FileExplorer's close-search behavior).
    private func dismiss() {
        clear()
        guard let window = focusTargetWindow else { return }
        _ = AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal()
    }

    private func clear() {
        query = ""
        results = []
        actionsById = [:]
        selectedIndex = 0
        // End the search session: the next search rebuilds a fresh corpus.
        cachedIndex = nil
        cachedActions = [:]
        cachedFingerprint = nil
    }
}

/// One dropdown row: kind icon, highlighted title, and the workspace context /
/// kind label. Holds only value data plus its select closure, never a store.
private struct SidebarTabSearchResultRow: View {
    let result: SidebarTabSearchResult
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    highlightedTitle
                        .cmuxFont(size: 12)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .cmuxFont(size: 10)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if let kindLabel = result.kindLabel, result.kind == .tab {
                    Text(kindLabel)
                        .cmuxFont(size: 9, weight: .medium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        result.kind == .workspace ? "rectangle.stack" : "rectangle"
    }

    /// Bolds/colors the title characters the fuzzy matcher matched, mirroring
    /// `ContentView.commandPaletteHighlightedTitleText`.
    private var highlightedTitle: Text {
        guard !result.titleMatchIndices.isEmpty else {
            return Text(result.title).foregroundColor(.primary)
        }
        let chars = Array(result.title)
        var index = 0
        var text = Text("")
        while index < chars.count {
            let isMatched = result.titleMatchIndices.contains(index)
            var end = index + 1
            while end < chars.count, result.titleMatchIndices.contains(end) == isMatched {
                end += 1
            }
            let segment = String(chars[index..<end])
            text = text + Text(segment).foregroundColor(isMatched ? .accentColor : .primary)
            index = end
        }
        return text
    }
}

/// Native single-line text field for the tab search, so ↑/↓/Return/Esc reach
/// the dropdown selection handlers instead of the field editor. Mirrors the
/// command palette's native-field approach.
///
/// Focus is driven by `focusToken`: each increment focuses the field once, so
/// the field never steals focus on an ordinary re-render and there is no
/// sustained focus state written back during a view update.
private struct SidebarTabSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let placeholder: String
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onMoveSelection: (Int) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = PlainTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        field.font = .systemFont(ofSize: 12)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.lastFocusToken = focusToken
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if placeholder != field.placeholderString {
            field.placeholderString = placeholder
        }
        // Focus exactly once per new token (the shortcut increments it). AppKit
        // focus manipulation from an AppKit bridge view is allowed; no SwiftUI
        // state is written here.
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SidebarTabSearchTextField
        var lastFocusToken: Int = 0

        init(_ parent: SidebarTabSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard !textView.hasMarkedText() else { return false }
                // `onEscape` restores terminal focus, which resigns the field.
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }

    /// Borderless, transparent single-line field so it blends into the search
    /// pill drawn by SwiftUI.
    final class PlainTextField: NSTextField {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            usesSingleLineMode = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
