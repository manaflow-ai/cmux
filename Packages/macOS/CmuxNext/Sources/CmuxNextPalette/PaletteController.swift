public import AppKit
public import CmuxNextActions
import SwiftUI

/// Which page the palette opens on.
public enum PaletteMode: Sendable, Hashable {
    case commands
    case keyboardShortcuts
    case workspaces
    case tabs
}

/// Owns the floating palette panel and wires the model to the registry and
/// the App's data sources.
///
/// Usage from the App:
/// ```swift
/// let palette = PaletteController(registry: registry, sources: sources)
/// palette.bindRegistryActions()   // Cmd-Shift-P, Cmd-P, shortcut search
/// ```
public final class PaletteController {
    public let registry: ActionRegistry
    public let model: PaletteModel
    public var sources: PaletteSources

    public private(set) var isVisible = false

    private var panel: PalettePanel?
    private weak var parentWindow: NSWindow?
    private var presentationGeneration = 0

    public init(
        registry: ActionRegistry,
        sources: PaletteSources = PaletteSources(),
        frecencyPersistence: (any FrecencyPersisting)? = UserDefaultsFrecencyPersistence()
    ) {
        self.registry = registry
        self.sources = sources
        self.model = PaletteModel(persistence: frecencyPersistence)
        model.onDismiss = { [weak self] in self?.hide() }
    }

    // MARK: Registry wiring

    /// Binds the palette's own catalog actions: Command Palette (toggle),
    /// Go to Workspace, Go to Tab, and Search Keyboard Shortcuts.
    public func bindRegistryActions() {
        registry.bind("commandPalette") { [weak self] in self?.toggle(.commands) }
        registry.bind("palette.searchShortcuts") { [weak self] in self?.show(.keyboardShortcuts) }
        if sources.workspaces != nil {
            registry.bind("goToWorkspace") { [weak self] in self?.show(.workspaces) }
        }
        if sources.tabs != nil {
            registry.bind("palette.goToTab") { [weak self] in self?.show(.tabs) }
        }
    }

    // MARK: Pages

    /// The root command list: every catalog action plus workspaces, tabs,
    /// directories, and settings once the user types.
    public func commandsPage() -> PalettePageSpec {
        var providers: [any PaletteProvider] = [makeRegistryProvider()]
        if let source = sources.workspaces {
            providers.append(WorkspacePaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        if let source = sources.tabs {
            providers.append(TabPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        if let source = sources.recentDirectories {
            providers.append(RecentDirectoriesPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        if let source = sources.settings {
            providers.append(SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: false))
        }
        providers += sources.extraProviders
        return PalettePageSpec(
            id: "commands",
            title: PaletteStrings.commandsTitle,
            placeholder: PaletteStrings.searchPlaceholder,
            symbol: "command",
            providers: providers,
            showsRecent: true
        )
    }

    public func keyboardShortcutsPage() -> PalettePageSpec {
        PalettePageSpec(
            id: "shortcuts",
            title: PaletteStrings.shortcutsTitle,
            placeholder: PaletteStrings.shortcutsPlaceholder,
            symbol: "keyboard",
            providers: [KeyboardShortcutsPaletteProvider(registry: registry)]
        )
    }

    public func workspacesPage() -> PalettePageSpec? {
        guard let source = sources.workspaces else { return nil }
        return PalettePageSpec(
            id: "workspaces",
            title: PaletteStrings.workspacesTitle,
            placeholder: PaletteStrings.workspacesPlaceholder,
            symbol: "rectangle.stack",
            providers: [WorkspacePaletteProvider(source: source, showsItemsForEmptyQuery: true)],
            showsRecent: true
        )
    }

    public func tabsPage() -> PalettePageSpec? {
        guard let source = sources.tabs else { return nil }
        return PalettePageSpec(
            id: "tabs",
            title: PaletteStrings.tabsTitle,
            placeholder: PaletteStrings.tabsPlaceholder,
            symbol: "rectangle.stack",
            providers: [TabPaletteProvider(source: source, showsItemsForEmptyQuery: true)],
            showsRecent: true
        )
    }

    private func openInPage() -> PalettePageSpec? {
        guard let source = sources.openIn else { return nil }
        return PalettePageSpec(
            id: "openIn",
            title: PaletteStrings.openInTitle,
            placeholder: PaletteStrings.openInPlaceholder,
            symbol: "arrow.up.forward.app",
            providers: [OpenInPaletteProvider(source: source, showsItemsForEmptyQuery: true)],
            showsRecent: true
        )
    }

    private func settingsPage() -> PalettePageSpec? {
        guard let source = sources.settings else { return nil }
        return PalettePageSpec(
            id: "settings",
            title: PaletteStrings.settingsTitle,
            placeholder: PaletteStrings.settingsPlaceholder,
            symbol: "switch.2",
            providers: [SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true)]
        )
    }

    /// Registry provider with the palette-served actions: nested lists and
    /// inline rename entries backed by the sources.
    private func makeRegistryProvider() -> RegistryPaletteProvider {
        let provider = RegistryPaletteProvider(registry: registry)
        provider.effectOverrides["palette.searchShortcuts"] = { [weak self] in
            self.map { .push($0.keyboardShortcutsPage()) }
        }
        provider.effectOverrides["goToWorkspace"] = { [weak self] in
            self?.workspacesPage().map { .push($0) }
        }
        provider.effectOverrides["palette.goToTab"] = { [weak self] in
            self?.tabsPage().map { .push($0) }
        }
        provider.effectOverrides["palette.terminalOpenDirectory"] = { [weak self] in
            self?.openInPage().map { .push($0) }
        }
        provider.effectOverrides["palette.toggleSetting"] = { [weak self] in
            self?.settingsPage().map { .push($0) }
        }
        provider.effectOverrides["renameTab"] = { [weak self] in
            guard let source = self?.sources.tabs, let tab = source.tabs.first(where: \.isSelected) else { return nil }
            return .textInput(PaletteTextInputSpec(
                id: "rename-tab:\(tab.id)",
                title: PaletteStrings.renameTab,
                placeholder: PaletteStrings.tabNamePlaceholder,
                initialText: tab.title,
                submitTitle: PaletteStrings.renameTo,
                submit: { source.renameTab(id: tab.id, to: $0) }
            ))
        }
        provider.effectOverrides["renameWorkspace"] = { [weak self] in
            guard let source = self?.sources.workspaces,
                  let workspace = source.workspaces.first(where: \.isSelected)
            else { return nil }
            return .textInput(PaletteTextInputSpec(
                id: "rename-workspace:\(workspace.id)",
                title: PaletteStrings.renameWorkspace,
                placeholder: PaletteStrings.workspaceNamePlaceholder,
                initialText: workspace.title,
                submitTitle: PaletteStrings.renameTo,
                submit: { source.renameWorkspace(id: workspace.id, to: $0) }
            ))
        }
        return provider
    }

    private func page(for mode: PaletteMode) -> PalettePageSpec {
        switch mode {
        case .commands: commandsPage()
        case .keyboardShortcuts: keyboardShortcutsPage()
        case .workspaces: workspacesPage() ?? commandsPage()
        case .tabs: tabsPage() ?? commandsPage()
        }
    }

    // MARK: Presentation

    public func toggle(_ mode: PaletteMode = .commands, relativeTo window: NSWindow? = nil) {
        if isVisible {
            hide()
        } else {
            show(mode, relativeTo: window)
        }
    }

    /// Opens the palette over `window` (default: the key or main window).
    public func show(_ mode: PaletteMode = .commands, relativeTo window: NSWindow? = nil) {
        let parent = window ?? NSApp.keyWindow.flatMap { $0 is PalettePanel ? nil : $0 } ?? NSApp.mainWindow
        let panel = self.panel ?? makePanel()
        presentationGeneration += 1
        model.reset(to: page(for: mode))
        registry.context.insert(.paletteOpen)

        if isVisible {
            // Already open: switch pages in place.
            panel.makeKey()
            return
        }
        isVisible = true
        parentWindow = parent
        panel.setFrame(frame(for: parent), display: false)
        if let parent, panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        model.isPresented = false
        panel.makeKeyAndOrderFront(nil)
        // Commit the collapsed state in one layout pass, then spring open.
        panel.contentView?.layoutSubtreeIfNeeded()
        withAnimation(openAnimation) {
            model.isPresented = true
        }
    }

    /// Closes the palette. The parent window becomes key immediately so a
    /// command that runs right after sees the right focus; the panel fades
    /// out, then orders out.
    public func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        registry.context.remove(.paletteOpen)
        model.closeActionsMenu()
        presentationGeneration += 1
        let generation = presentationGeneration
        if let parentWindow, parentWindow.isVisible {
            parentWindow.makeKey()
        }
        withAnimation(closeAnimation, completionCriteria: .logicallyComplete) {
            model.isPresented = false
        } completion: { [weak self, weak panel] in
            guard let self, let panel, self.presentationGeneration == generation else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var openAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.26, bounce: 0.18)
    }

    private var closeAnimation: Animation {
        reduceMotion ? .easeIn(duration: 0.1) : .spring(duration: 0.16, bounce: 0)
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(size: PaletteMetrics.windowSize)
        let hosting = NSHostingView(rootView: PaletteRootView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: PaletteMetrics.windowSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.keyHandler = { [weak self] event in self?.handleKeyDown(event) ?? false }
        panel.onResignKey = { [weak self] in
            // Clicking elsewhere closes the palette, like Spotlight.
            self?.hide()
        }
        self.panel = panel
        return panel
    }

    /// Top-centered over the parent window at about a fifth of its height,
    /// clamped to the visible screen.
    private func frame(for parent: NSWindow?) -> NSRect {
        let size = PaletteMetrics.windowSize
        let screen = parent?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = parent?.frame ?? visible
        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.maxY - anchor.height * 0.16 - size.height + PaletteMetrics.shadowMargin
        )
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    // MARK: Keys

    /// Maps a key-down in the panel to a palette command. Returns true when
    /// the event was consumed (so the text field never sees it).
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let command = PaletteKeyMap.command(
            for: event,
            actionsMenuOpen: model.actionsMenu != nil,
            queryIsEmpty: model.query.isEmpty,
            registry: registry
        ) else { return false }
        return model.handle(command)
    }
}
