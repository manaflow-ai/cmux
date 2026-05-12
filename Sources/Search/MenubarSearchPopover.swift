import AppKit
import SwiftUI

@MainActor
final class MenubarSearchPopover: NSObject, NSPopoverDelegate {
    private unowned let coordinator: GlobalSearchCoordinator
    private let popover = NSPopover()

    init(coordinator: GlobalSearchCoordinator) {
        self.coordinator = coordinator
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 720, height: 460)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: GlobalSearchPaletteView(coordinator: coordinator)
        )
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            dismiss()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func dismiss() {
        popover.performClose(nil)
    }
}

private struct GlobalSearchPaletteView: View {
    let coordinator: GlobalSearchCoordinator

    @State private var query = ""
    @State private var results: [GlobalSearchResultRow] = []
    @State private var selectedIndex = 0
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    String(
                        localized: "globalSearch.palette.placeholder",
                        defaultValue: "Search all windows, panels, browser tabs..."
                    ),
                    text: $query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($searchFieldFocused)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Divider()

            if results.isEmpty {
                GlobalSearchEmptyStateView(
                    title: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(localized: "globalSearch.empty.prompt", defaultValue: "Type to search")
                        : String(localized: "globalSearch.empty.noResults", defaultValue: "No results")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { row in
                        GlobalSearchResultRowView(
                            row: row,
                            isSelected: selectedIndex == row.index,
                            action: {
                                selectedIndex = row.index
                                openSelectedResult()
                            }
                            )
                            .onHover { hovering in
                                if hovering {
                                    selectedIndex = row.index
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 720, height: 460)
        .background(.regularMaterial)
        .onAppear {
            searchFieldFocused = true
            installKeyMonitorIfNeeded()
            Task { await coordinator.refreshLiveIndex() }
        }
        .onDisappear {
            removeKeyMonitor()
            searchTask?.cancel()
            searchTask = nil
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
    }

    private func scheduleSearch(_ nextQuery: String) {
        searchTask?.cancel()
        let trimmed = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            results = []
            selectedIndex = 0
            return
        }

        isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let hits = await coordinator.search(query: trimmed)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                results = hits.enumerated().map { offset, hit in
                    GlobalSearchResultRow(hit: hit, query: trimmed, index: offset)
                }
                selectedIndex = min(selectedIndex, max(results.count - 1, 0))
                isSearching = false
            }
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handleKeyEvent(event) ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control),
           let rawDigit = event.charactersIgnoringModifiers,
           let digit = Int(rawDigit),
           (1...9).contains(digit) {
            openResult(at: digit - 1)
            return true
        }

        switch event.keyCode {
        case 53:
            coordinator.dismissPalette()
            return true
        case 126:
            selectedIndex = max(0, selectedIndex - 1)
            return true
        case 125:
            selectedIndex = min(max(results.count - 1, 0), selectedIndex + 1)
            return true
        case 36, 76:
            openSelectedResult()
            return true
        default:
            return false
        }
    }

    private func openSelectedResult() {
        openResult(at: selectedIndex)
    }

    private func openResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        let row = results[index]
        coordinator.activate(row.hit, query: row.query)
    }
}

private struct GlobalSearchEmptyStateView: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private struct GlobalSearchResultRow: Identifiable, Equatable {
    let hit: SearchIndexHit
    let query: String
    let index: Int

    var id: String { hit.id }

    var title: String {
        let trimmed = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "globalSearch.untitled", defaultValue: "Untitled")
            : trimmed
    }

    var location: String {
        hit.location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var snippet: String {
        let trimmed = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    var shortcutLabel: String? {
        index < 9 ? "⌘\(index + 1)" : nil
    }

    var systemImageName: String {
        switch hit.kind {
        case .browser:
            return "globe"
        case .markdown:
            return "doc.richtext"
        case .title:
            return "rectangle.stack"
        }
    }
}

private struct GlobalSearchResultRowView: View {
    let row: GlobalSearchResultRow
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: row.systemImageName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(row.hit.kind.localizedLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(row.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !row.location.isEmpty {
                        Text(row.location)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let shortcutLabel = row.shortcutLabel {
                    Text(shortcutLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
