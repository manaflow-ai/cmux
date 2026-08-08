import CmuxFoundation
import AppKit
import SwiftUI

@MainActor
final class MenubarSearchPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let presentation: GlobalSearchPopoverPresentation

    var isShown: Bool {
        presentation.isPresented
    }

    init(coordinator: GlobalSearchCoordinator) {
        presentation = GlobalSearchPopoverPresentation(coordinator: coordinator)
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 720, height: 460)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: GlobalSearchPaletteView(
                presentation: presentation
            )
        )
    }

    private var dismissalHandler: (() -> Void)?

    func toggle(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if presentation.isPresented {
            dismiss()
        } else {
            show(relativeTo: button, onDismiss: onDismiss)
        }
    }

    func show(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        // isPresented stays true until this popover's did-close callback, so a
        // closing presentation cannot be replaced before its teardown runs.
        guard !isShown else { return }
        dismissalHandler = onDismiss
        presentation.beginPresentation()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func dismiss() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        presentation.endPresentation()
        let handler = dismissalHandler
        dismissalHandler = nil
        handler?()
    }
}

private struct GlobalSearchPaletteView: View {
    @Bindable var presentation: GlobalSearchPopoverPresentation

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .cmuxFont(size: 15, weight: .semibold)
                    .foregroundStyle(.secondary)
                TextField(
                    String(
                        localized: "globalSearch.palette.placeholder",
                        defaultValue: "Search all windows, panels, browser tabs..."
                    ),
                    text: $presentation.query
                )
                .textFieldStyle(.plain)
                .cmuxFont(size: 18, weight: .regular)
                .focused($searchFieldFocused)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Divider()

            if presentation.results.isEmpty {
                GlobalSearchEmptyStateView(
                    title: presentation.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(localized: "globalSearch.empty.noOpenPanels", defaultValue: "No open panels")
                        : String(localized: "globalSearch.empty.noResults", defaultValue: "No results")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(presentation.results) { row in
                            GlobalSearchResultRowView(
                                row: row,
                                isSelected: presentation.selectedIndex == row.index,
                                action: {
                                    presentation.selectResult(at: row.index)
                                    presentation.activateSelectedResult()
                                }
                            )
                            .onHover { hovering in
                                if hovering {
                                    presentation.selectResult(at: row.index)
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
        .onChange(of: presentation.isPresented, initial: true) { _, isPresented in
            searchFieldFocused = isPresented
        }
    }
}

struct GlobalSearchKeyEvent: Sendable {
    let keyCode: UInt16
    let characters: String?
    let charactersIgnoringModifiers: String?
    private let modifierFlagsRawValue: UInt

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        characters = event.characters
        charactersIgnoringModifiers = event.charactersIgnoringModifiers
        modifierFlagsRawValue = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }
}

private struct GlobalSearchEmptyStateView: View {
    let title: String

    var body: some View {
        Text(title)
            .cmuxFont(size: 14, weight: .medium)
            .foregroundStyle(.secondary)
    }
}

struct GlobalSearchResultRow: Identifiable, Equatable {
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
                    .cmuxFont(size: 14, weight: .semibold)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.title)
                            .cmuxFont(size: 13, weight: .semibold)
                            .lineLimit(1)
                        Text(row.hit.kind.localizedLabel)
                            .cmuxFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(row.snippet)
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !row.location.isEmpty {
                        Text(row.location)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let shortcutLabel = row.shortcutLabel {
                    Text(shortcutLabel)
                        .cmuxFont(size: 11, weight: .medium, design: .monospaced)
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
