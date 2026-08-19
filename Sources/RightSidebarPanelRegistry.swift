import AppKit
import CmuxSettings
import SwiftUI

/// First-party registry for right-sidebar panels.
///
/// Availability closures read the beta catalog section directly. This keeps
/// synchronous paths cheap and avoids reconstructing the full setting catalog
/// while still giving SwiftUI live setting bindings the authority to trigger a
/// mode refresh.
enum RightSidebarPanelRegistry {
    static func descriptors(defaults: UserDefaults = .standard) -> [RightSidebarPanelDescriptor] {
        let beta = BetaFeaturesCatalogSection()
        let feedKey = beta.rightSidebarFeed
        let dockKey = beta.rightSidebarDock
        let sourceControlKey = beta.sourceControl

        return [
            descriptor(
                id: RightSidebarMode.files.rawValue,
                title: String(localized: "rightSidebar.mode.files", defaultValue: "Files"),
                symbolName: "folder",
                order: 10,
                shortcutAction: .switchRightSidebarToFiles,
                cliArgument: "files",
                commandPaletteCommandID: "palette.showRightSidebarFiles",
                paneCommandID: "palette.openFilesPane",
                paneTitle: String(localized: "command.openFilesPane.title", defaultValue: "Open Files as Pane"),
                supportsTearOffPane: true,
                syncsFileExplorerRoot: true
            ) { context in
                AnyView(
                    FileExplorerPanelView(
                        store: context.fileExplorerStore,
                        state: context.fileExplorerState,
                        onOpenFilePreview: context.onOpenFilePreview,
                        presentation: .files
                    )
                )
            },
            descriptor(
                id: RightSidebarMode.find.rawValue,
                title: String(localized: "rightSidebar.mode.find", defaultValue: "Find"),
                symbolName: "magnifyingglass",
                order: 20,
                shortcutAction: .switchRightSidebarToFind,
                cliArgument: "find",
                commandPaletteCommandID: "palette.showRightSidebarFind",
                paneCommandID: "palette.openFindPane",
                paneTitle: String(localized: "command.openFindPane.title", defaultValue: "Open Find as Pane"),
                supportsTearOffPane: true,
                syncsFileExplorerRoot: true
            ) { context in
                AnyView(
                    FileExplorerPanelView(
                        store: context.fileExplorerStore,
                        state: context.fileExplorerState,
                        onOpenFilePreview: context.onOpenFilePreview,
                        presentation: .find
                    )
                )
            },
            descriptor(
                id: RightSidebarMode.sessions.rawValue,
                title: String(localized: "rightSidebar.mode.sessions", defaultValue: "Vault"),
                symbolName: "books.vertical",
                order: 30,
                shortcutAction: .switchRightSidebarToSessions,
                cliArgument: "vault",
                commandPaletteCommandID: "palette.showRightSidebarSessions",
                paneCommandID: "palette.openVaultPane",
                paneTitle: String(localized: "command.openVaultPane.title", defaultValue: "Open Vault as Pane"),
                supportsTearOffPane: true,
                syncsFileExplorerRoot: false
            ) { context in
                AnyView(
                    SessionIndexView(
                        store: context.sessionIndexStore,
                        chromeBackgroundColor: context.windowAppearance.resolvedChromeBackgroundColor,
                        onResume: context.onResumeSession
                    )
                    .onAppear {
                        context.sessionIndexStore.setCurrentDirectoryIfChanged(context.sessionIndexDirectory)
                    }
                )
            },
            descriptor(
                id: RightSidebarMode.feed.rawValue,
                title: String(localized: "rightSidebar.mode.feed", defaultValue: "Feed"),
                symbolName: "dot.radiowaves.left.and.right",
                order: 40,
                isAvailable: { Self.isEnabled(feedKey, defaults: defaults) },
                shortcutAction: .switchRightSidebarToFeed,
                cliArgument: "feed",
                commandPaletteCommandID: "palette.showRightSidebarFeed",
                paneCommandID: nil,
                paneTitle: nil,
                supportsTearOffPane: false,
                syncsFileExplorerRoot: false
            ) { context in
                AnyView(FeedPanelView(chromeBackgroundColor: context.windowAppearance.resolvedChromeBackgroundColor))
            },
            descriptor(
                id: RightSidebarMode.dock.rawValue,
                title: String(localized: "rightSidebar.mode.dock", defaultValue: "Dock"),
                symbolName: "dock.rectangle",
                order: 50,
                isAvailable: { Self.isEnabled(dockKey, defaults: defaults) },
                shortcutAction: .switchRightSidebarToDock,
                cliArgument: "dock",
                commandPaletteCommandID: "palette.showRightSidebarDock",
                paneCommandID: nil,
                paneTitle: nil,
                supportsTearOffPane: false,
                syncsFileExplorerRoot: false
            ) { context in
                AnyView(RightSidebarDockPanelContent(context: context))
            },
            descriptor(
                id: RightSidebarMode.sourceControl.rawValue,
                title: String(localized: "rightSidebar.mode.sourceControl", defaultValue: "Source Control"),
                symbolName: "arrow.triangle.branch",
                order: 60,
                isAvailable: { Self.isEnabled(sourceControlKey, defaults: defaults) },
                shortcutAction: .switchRightSidebarToSourceControl,
                cliArgument: "source-control",
                commandPaletteCommandID: "palette.showRightSidebarSourceControl",
                paneCommandID: nil,
                paneTitle: nil,
                supportsTearOffPane: false,
                syncsFileExplorerRoot: true
            ) { context in
                AnyView(SourceControlPanelView(context: context))
            },
        ].sorted { $0.order < $1.order }
    }

    static func descriptor(
        for mode: RightSidebarMode,
        defaults: UserDefaults = .standard
    ) -> RightSidebarPanelDescriptor? {
        descriptors(defaults: defaults).first { $0.id == mode.rawValue }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        descriptors(defaults: defaults).compactMap { descriptor in
            guard descriptor.isAvailable(), let mode = RightSidebarMode(rawValue: descriptor.id) else {
                return nil
            }
            return mode
        }
    }

    static func makeContent(
        for mode: RightSidebarMode,
        context: RightSidebarPanelContext,
        defaults: UserDefaults = .standard
    ) -> AnyView {
        guard let descriptor = descriptor(for: mode, defaults: defaults), descriptor.isAvailable() else {
            return AnyView(Color.clear)
        }
        return descriptor.makeContent(context)
    }

    private static func descriptor(
        id: String,
        title: String,
        symbolName: String,
        order: Int,
        isAvailable: @escaping () -> Bool = { true },
        shortcutAction: KeyboardShortcutSettings.Action?,
        cliArgument: String,
        commandPaletteCommandID: String,
        paneCommandID: String?,
        paneTitle: String?,
        supportsTearOffPane: Bool,
        syncsFileExplorerRoot: Bool,
        makeContent: @escaping (RightSidebarPanelContext) -> AnyView
    ) -> RightSidebarPanelDescriptor {
        RightSidebarPanelDescriptor(
            id: id,
            title: title,
            symbolName: symbolName,
            order: order,
            isAvailable: isAvailable,
            shortcutAction: shortcutAction,
            cliArgument: cliArgument,
            commandPaletteCommandID: commandPaletteCommandID,
            paneCommandID: paneCommandID,
            paneTitle: paneTitle,
            supportsTearOffPane: supportsTearOffPane,
            syncsFileExplorerRoot: syncsFileExplorerRoot,
            makeContent: makeContent
        )
    }

    private static func isEnabled(
        _ key: DefaultsKey<Bool>,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key.userDefaultsKey) != nil else {
            return key.defaultValue
        }
        return defaults.bool(forKey: key.userDefaultsKey)
    }
}

private struct RightSidebarDockPanelContent: View {
    let context: RightSidebarPanelContext

    var body: some View {
        if let app = AppDelegate.shared,
           let dock = app.windowDock(for: context.tabManager) {
            DockPanelView(
                store: dock,
                isSidebarVisible: context.fileExplorerState.isVisible,
                mode: context.fileExplorerState.mode,
                rootDirectory: nil,
                windowAppearance: context.windowAppearance,
                rightSidebarOwnsInputFocus: context.fileExplorerState.rightSidebarOwnsInputFocus,
                unreadSource: TerminalNotificationStore.shared.sidebarUnread
            )
            .id("dock.window.\(dock.workspaceId.uuidString)")
        } else {
            Color.clear
        }
    }
}
