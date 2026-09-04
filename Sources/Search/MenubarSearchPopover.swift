import CmuxFoundation
import AppKit
import SwiftUI

@MainActor
final class MenubarSearchPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model: GlobalSearchPaletteModel
    private var keyMonitor: Any?

    var isShown: Bool {
        popover.isShown
    }

    init(coordinator: GlobalSearchCoordinator) {
        self.model = GlobalSearchPaletteModel(client: .init(
            refreshLiveIndex: { [unowned coordinator] in await coordinator.refreshLiveIndex() },
            search: { [unowned coordinator] query in await coordinator.search(query: query) },
            browseOpenPanels: { [unowned coordinator] limit in coordinator.browseOpenPanels(limit: limit) },
            activate: { [unowned coordinator] hit, query in coordinator.activate(hit, query: query) },
            dismissPalette: { [unowned coordinator] in coordinator.dismissPalette() },
            isPaletteVisible: { [unowned coordinator] in coordinator.isPaletteVisible() }
        ))
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 720, height: 460)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: GlobalSearchPaletteView(model: model)
        )
    }

    private var dismissalHandler: (() -> Void)?

    func toggle(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if popover.isShown {
            dismiss()
        } else {
            show(relativeTo: button, onDismiss: onDismiss)
        }
    }

    func show(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if popover.isShown {
            popover.performClose(nil)
        }
        dismissalHandler = onDismiss
        // The hosting controller retains its content view across shows, so
        // SwiftUI onAppear only fires for the first open. Drive the per-open
        // lifecycle (state reset, live re-index, key monitor) from here (#7445).
        model.prepareForOpen()
        installKeyMonitorIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func dismiss() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        removeKeyMonitor()
        model.handleDidClose()
        let handler = dismissalHandler
        dismissalHandler = nil
        handler?()
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            let keyEvent = GlobalSearchKeyEvent(event)
            let route = MainActor.assumeIsolated {
                AppDelegate.shared?
                    .routeVisibleGlobalSearchShortcutFromLocalMonitor(event)
                    ?? .notApplicable
            }
            switch route {
            case .handled:
                return nil
            case .queryOwnsEvent:
                return event
            case .notApplicable:
                let consumed = MainActor.assumeIsolated {
                    model?.handleKeyEvent(keyEvent) ?? false
                }
                return consumed ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private struct GlobalSearchPaletteView: View {
    @ObservedObject var model: GlobalSearchPaletteModel
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
                    text: $model.query
                )
                .textFieldStyle(.plain)
                .cmuxFont(size: 18, weight: .regular)
                .focused($searchFieldFocused)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Divider()

            if model.results.isEmpty {
                GlobalSearchEmptyStateView(
                    title: model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(localized: "globalSearch.empty.noOpenPanels", defaultValue: "No open panels")
                        : String(localized: "globalSearch.empty.noResults", defaultValue: "No results")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.results) { row in
                            GlobalSearchResultRowView(
                                row: row,
                                isSelected: model.selectedIndex == row.index,
                                action: {
                                    model.selectedIndex = row.index
                                    model.openSelectedResult()
                                }
                            )
                            .onHover { hovering in
                                if hovering {
                                    model.selectedIndex = row.index
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
        }
        .onChange(of: model.openGeneration) { _, _ in
            searchFieldFocused = true
        }
        .onChange(of: model.query) { _, newValue in
            model.queryDidChange(newValue)
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
