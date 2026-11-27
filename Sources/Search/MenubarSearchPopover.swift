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
    private var fallbackAnchorPanel: NSPanel?
    private let fallbackAnchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))

    func toggle(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        // A popover AppKit placed off every screen counts as shown but is not
        // visible; toggling it must show the palette, not close the phantom.
        if popover.isShown, !presentedWindowIsOffScreen {
            dismiss()
        } else {
            show(relativeTo: button, onDismiss: onDismiss)
        }
    }

    func show(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        closeImmediately()
        if let buttonWindow = button.window, !Self.isOffScreen(buttonWindow.frame) {
            fallbackAnchorPanel?.orderOut(nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        if !popover.isShown || presentedWindowIsOffScreen {
            // macOS places a status item asynchronously and may leave it
            // unplaced when the menu bar is full or hidden. Anchored to such a
            // button, the popover opens at an infinite origin and never
            // appears, so present it under the menu bar of the active screen.
            closeImmediately()
            let anchor = presentFallbackAnchor()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        dismissalHandler = onDismiss
        // The hosting controller retains its content view across shows, so
        // SwiftUI onAppear only fires for the first open. Drive the per-open
        // lifecycle (state reset, live re-index, key monitor) from here (#7445),
        // after any fallback re-present above, whose close runs finishClose.
        guard popover.isShown else { return }
        model.prepareForOpen()
        installKeyMonitorIfNeeded()
    }

    /// Closes without the fade-out. An animated close only finishes when the
    /// window server keeps drawing the popover, and one that never finishes
    /// leaves `isShown` true, so every later toggle would close instead of show.
    func dismiss() {
        closeImmediately()
    }

    func popoverDidClose(_ notification: Notification) {
        finishClose()
    }

    private func closeImmediately() {
        guard popover.isShown else { return }
        let animates = popover.animates
        popover.animates = false
        popover.close()
        popover.animates = animates
        finishClose()
    }

    private func finishClose() {
        // A close that finishes animating after the next show must not pull
        // the anchor out from under the popover that show presented.
        guard !popover.isShown else { return }
        fallbackAnchorPanel?.orderOut(nil)
        removeKeyMonitor()
        model.handleDidClose()
        let handler = dismissalHandler
        dismissalHandler = nil
        handler?()
    }

    private var presentedWindowIsOffScreen: Bool {
        guard let frame = popover.contentViewController?.view.window?.frame else { return false }
        return Self.isOffScreen(frame)
    }

    /// True for a frame AppKit placed at an infinite origin or off every
    /// screen. An empty frame is not yet placed, so it is not judged.
    static func isOffScreen(_ frame: NSRect) -> Bool {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite else {
            return true
        }
        guard !frame.isEmpty else { return false }
        return !NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    private func presentFallbackAnchor() -> NSView {
        let panel = fallbackAnchorPanel ?? makeFallbackAnchorPanel()
        fallbackAnchorPanel = panel
        let screen = NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrame(
                NSRect(x: visibleFrame.midX, y: visibleFrame.maxY - 1, width: 1, height: 1),
                display: false
            )
        }
        panel.orderFrontRegardless()
        return fallbackAnchorView
    }

    private func makeFallbackAnchorPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = fallbackAnchorView
        return panel
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
                        Text(row.kindLabel)
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
