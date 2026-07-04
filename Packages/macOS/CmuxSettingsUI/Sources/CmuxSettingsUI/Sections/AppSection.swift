import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **App** section — mirrors the legacy in-app section row-for-row
/// inside a single `SettingsCard`: Language, Appearance, App Icon,
/// New Workspace Placement, Inherit Working Directory, Minimal Mode,
/// Keep Workspace Open When Closing Last Surface, Focus Pane on
/// First Click, File Drops, Open Files With, Open Supported Files in
/// cmux, Terminal Config link, Open Markdown in cmux Viewer,
/// Markdown Viewer typography, iMessage Mode, Reorder on Notification, Dock Badge, Menu Bar
/// Only, Show in Menu Bar, Unread Pane Ring, Pane Flash, Desktop
/// Notifications, Notification Sound, Notification Command, Send
/// anonymous telemetry, Warn Before Quit, Warn Before Closing Tab /
/// X Button / Hide Tab Close Button, Rename Selects Existing Name,
/// Command Palette Searches All Surfaces.
@MainActor
public struct AppSection: View {
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions

    // Every bound value-model lives here as view state, constructed once
    // and persisted across renders so the @Observable change tracking
    // actually drives invalidation.
    @State private var language: DefaultsValueModel<AppLanguage>
    @State private var appearance: DefaultsValueModel<AppearanceMode>
    @State private var appIcon: DefaultsValueModel<AppIconMode>
    @State private var placement: DefaultsValueModel<WorkspacePlacement>
    @State private var inheritDir: DefaultsValueModel<Bool>
    @State private var minimalMode: DefaultsValueModel<WorkspacePresentationMode>
    @State private var keepWorkspaceOpen: DefaultsValueModel<Bool>
    @State private var firstClick: DefaultsValueModel<Bool>
    @State private var fileDrop: DefaultsValueModel<FileDropDefaultBehavior>
    @State private var preferredEditor: DefaultsValueModel<String>
    @State private var openSupported: DefaultsValueModel<Bool>
    @State private var openMarkdown: DefaultsValueModel<Bool>
    @State private var globalFontMagnification: DefaultsValueModel<Int>
    @State private var markdownFontSize: DefaultsValueModel<Int>
    @State private var markdownFontFamily: DefaultsValueModel<String>
    @State private var markdownMaxWidth: DefaultsValueModel<Int>
    @State private var canvasPaneGap: DefaultsValueModel<Int>
    @State private var canvasSnapping: DefaultsValueModel<Bool>
    @State private var fileEditorWordWrap: DefaultsValueModel<Bool>
    @State private var iMessage: DefaultsValueModel<Bool>
    @State private var reorder: DefaultsValueModel<Bool>
    @State private var dockBadge: DefaultsValueModel<Bool>
    @State private var menuBarOnly: DefaultsValueModel<Bool>
    @State private var showInMenuBar: DefaultsValueModel<Bool>
    @State private var paneRing: DefaultsValueModel<Bool>
    @State private var paneFlash: DefaultsValueModel<Bool>
    @State private var desktopNotifications: DesktopNotificationAuthorizationModel
    @State private var agentPermissionPrompt: DefaultsValueModel<Bool>
    @State private var agentTurnComplete: DefaultsValueModel<String>
    @State private var agentIdleReminder: DefaultsValueModel<Bool>
    @State private var soundName: DefaultsValueModel<String>
    @State private var soundCommand: DefaultsValueModel<String>
    @State private var customSoundFile: DefaultsValueModel<String>
    @State private var telemetry: DefaultsValueModel<Bool>
    @State private var confirmQuit: DefaultsValueModel<ConfirmQuitMode>
    @State private var warnCloseTab: DefaultsValueModel<Bool>
    @State private var warnCloseX: DefaultsValueModel<Bool>
    @State private var hideCloseButton: DefaultsValueModel<Bool>
    @State private var renameSelects: DefaultsValueModel<Bool>
    @State private var paletteAllSurfaces: DefaultsValueModel<Bool>

    @State private var languageAtAppear: AppLanguage?
    @State private var telemetryAtAppear: Bool?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions
    ) {
        self.catalog = catalog
        self.hostActions = hostActions
        _language = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.language))
        _appearance = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.appearance))
        _appIcon = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.appIcon))
        _placement = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.newWorkspacePlacement))
        _inheritDir = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.workspaceInheritWorkingDirectory))
        _minimalMode = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.presentationMode))
        _keepWorkspaceOpen = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.keepWorkspaceOpenWhenClosingLastSurface))
        _firstClick = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.focusPaneOnFirstClick))
        _fileDrop = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.fileDropDefaultBehavior))
        _preferredEditor = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.preferredEditor))
        _openSupported = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.openSupportedFilesInCmux))
        _openMarkdown = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.openMarkdownInCmuxViewer))
        _globalFontMagnification = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.globalFontMagnification))
        _markdownFontSize = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.fontSize))
        _markdownFontFamily = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.fontFamily))
        _markdownMaxWidth = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.maxWidth))
        _canvasPaneGap = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.canvas.paneGap))
        _canvasSnapping = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.canvas.snappingEnabled))
        _fileEditorWordWrap = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.wordWrap))
        _iMessage = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.iMessageMode))
        _reorder = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.reorderOnNotification))
        _dockBadge = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.dockBadge))
        _menuBarOnly = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.menuBarOnly))
        _showInMenuBar = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.showInMenuBar))
        _paneRing = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.unreadPaneRing))
        _paneFlash = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.paneFlash))
        _desktopNotifications = State(initialValue: DesktopNotificationAuthorizationModel(hostActions: hostActions))
        _agentPermissionPrompt = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.agentPermissionPrompt))
        _agentTurnComplete = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.agentTurnComplete))
        _agentIdleReminder = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.agentIdleReminder))
        _soundName = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.sound))
        _soundCommand = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.command))
        _customSoundFile = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.customSoundFilePath))
        _telemetry = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.sendAnonymousTelemetry))
        _confirmQuit = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.confirmQuitMode))
        _warnCloseTab = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingTab))
        _warnCloseX = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingTabXButton))
        _hideCloseButton = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.hideTabCloseButton))
        _renameSelects = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.renameSelectsExistingName))
        _paletteAllSurfaces = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.commandPaletteSearchesAllSurfaces))
    }

    private static let columnWidth: CGFloat = 196
    private static let notificationSoundControlWidth: CGFloat = 280

    /// Languages legacy `AppLanguage` exposes (cmuxApp.swift line
    /// 4338). The shared `CmuxSettings.AppLanguage` adds `.vi` for a
    /// future Vietnamese localization that the legacy in-app picker
    /// doesn't surface yet; filter it out here so the Settings UI
    /// matches the legacy menu shape exactly.
    private static let legacyLanguageCases: [AppLanguage] = [
        .system, .en, .ar, .bs, .zhHans, .zhHant, .da, .de, .es, .fr,
        .it, .ja, .ko, .nb, .pl, .ptBR, .ru, .th, .tr,
    ]

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.app", defaultValue: "App"), section: .app)
                .accessibilityIdentifier("SettingsAppSection")
            mainCard
        }
        .task {
            startSettingsObservation([language, appearance, appIcon, placement, inheritDir, minimalMode, keepWorkspaceOpen, firstClick, fileDrop, preferredEditor, openSupported, openMarkdown, globalFontMagnification, markdownFontSize, markdownFontFamily, markdownMaxWidth, canvasPaneGap, canvasSnapping, fileEditorWordWrap, iMessage, reorder, dockBadge, menuBarOnly, showInMenuBar, paneRing, paneFlash, desktopNotifications, agentPermissionPrompt, agentTurnComplete, agentIdleReminder, soundName, soundCommand, customSoundFile, telemetry, confirmQuit, warnCloseTab, warnCloseX, hideCloseButton, renameSelects, paletteAllSurfaces])
            if languageAtAppear == nil { languageAtAppear = language.current }; if telemetryAtAppear == nil { telemetryAtAppear = telemetry.current }
        }
    }

    private var globalFontMagnificationSubtitle: String {
        if globalFontMagnification.current != GlobalFontMagnification.defaultPercent {
            return String(
                localized: "settings.app.globalFontMagnification.subtitleOn",
                defaultValue: "Terminals, tabs, and chrome all render at this magnification. Per-pane zoom (Cmd= / Cmd-) still overrides for the focused pane."
            )
        }
        return String(
            localized: "settings.app.globalFontMagnification.subtitleOff",
            defaultValue: "Scale every font in cmux by the same percentage. 100% = design size."
        )
    }

    private func setGlobalFontMagnification(_ percent: Int) {
        let clamped = GlobalFontMagnification.clamp(percent)
        globalFontMagnification.set(clamped) { NotificationCenter.default.post(name: GlobalFontMagnification.didChangeNotification, object: nil) }
    }

    @ViewBuilder
    private var mainCard: some View {
        SettingsCard {
            // Language
            SettingsCardRow(
                configurationReview: .json("app.language"),
                String(localized: "settings.app.language", defaultValue: "Language"),
                subtitle: languageAtAppear != nil && language.current != languageAtAppear
                    ? String(localized: "settings.app.language.restartSubtitle", defaultValue: "Restart cmux to apply")
                    : nil,
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { language.current }, set: { language.set($0) })) {
                    ForEach(Self.legacyLanguageCases, id: \.self) { lang in
                        Text(languageDisplayName(lang)).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Theme — three-up visual picker mirroring legacy
            ThemePickerRow(
                selectedMode: appearance.current,
                onSelect: { appearance.set($0) }
            )
            .settingsSearchAnchors(["setting:app:appearance"])
            SettingsCardDivider()

            // App Icon — three-up visual picker mirroring legacy
            AppIconPickerRow(
                selectedMode: appIcon.current,
                onSelect: { appIcon.set($0) }
            )
            .settingsSearchAnchors(["setting:app:app-icon"])
            SettingsCardDivider()

            // New Workspace Placement
            SettingsCardRow(
                configurationReview: .json("app.newWorkspacePlacement"),
                String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"),
                subtitle: workspacePlacementSubtitle(placement.current),
                controlWidth: Self.columnWidth
            ) {
                // Order matches legacy NewWorkspacePlacement.allCases:
                // top, afterCurrent, end.
                Picker("", selection: Binding(get: { placement.current }, set: { placement.set($0) })) {
                    Text(String(localized: "workspace.placement.top", defaultValue: "Top")).tag(WorkspacePlacement.top)
                    Text(String(localized: "workspace.placement.afterCurrent", defaultValue: "After current")).tag(WorkspacePlacement.afterCurrent)
                    Text(String(localized: "workspace.placement.end", defaultValue: "End")).tag(WorkspacePlacement.end)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Inherit Working Directory
            SettingsCardRow(
                configurationReview: .json("app.workspaceInheritWorkingDirectory"),
                String(localized: "settings.app.workspaceInheritWorkingDirectory", defaultValue: "Inherit Workspace Working Directory"),
                subtitle: inheritDir.current
                    ? String(localized: "settings.app.workspaceInheritWorkingDirectory.subtitleOn", defaultValue: "New workspaces start in the focused workspace's working directory.")
                    : String(localized: "settings.app.workspaceInheritWorkingDirectory.subtitleOff", defaultValue: "New workspaces leave their working directory unset so Ghostty's working-directory setting can apply.")
            ) {
                Toggle("", isOn: Binding(get: { inheritDir.current }, set: { inheritDir.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsWorkspaceInheritWorkingDirectoryToggle")
            }
            SettingsCardDivider()

            // Minimal Mode
            SettingsCardRow(
                configurationReview: .json("app.minimalMode"),
                String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode"),
                subtitle: minimalMode.current == .minimal
                    ? String(localized: "settings.app.minimalMode.subtitleOn", defaultValue: "Hide the workspace title bar and move workspace controls into the sidebar.")
                    : String(localized: "settings.app.minimalMode.subtitleOff", defaultValue: "Use the standard workspace title bar and controls.")
            ) {
                Toggle("", isOn: Binding(
                    get: { minimalMode.current == .minimal },
                    set: { minimalMode.set($0 ? .minimal : .standard) }
                ))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMinimalModeToggle")
            }
            SettingsCardDivider()

            // Keep Workspace Open. The stored value carries close-on-last-
            // surface semantics (true = close), so the "Keep Open" toggle
            // and its subtitle bind to the inverse, matching legacy.
            SettingsCardRow(
                configurationReview: .json("app.keepWorkspaceOpenWhenClosingLastSurface"),
                String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut", defaultValue: "Keep Workspace Open When Closing Last Surface"),
                subtitle: !keepWorkspaceOpen.current
                    ? String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut.subtitleOn", defaultValue: "When the focused surface is the last one in its workspace, closing it with the close-surface shortcut, tab close button, or middle-click closes only the surface and keeps the workspace open. Use the close-workspace shortcut to close the workspace explicitly.")
                    : String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut.subtitleOff", defaultValue: "When the focused surface is the last one in its workspace, closing it with the close-surface shortcut, tab close button, or middle-click also closes the workspace.")
            ) {
                Toggle("", isOn: Binding(get: { !keepWorkspaceOpen.current }, set: { keepWorkspaceOpen.set(!$0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Focus Pane on First Click
            SettingsCardRow(
                configurationReview: .json("app.focusPaneOnFirstClick"),
                String(localized: "settings.app.paneFirstClickFocus", defaultValue: "Focus Pane on First Click"),
                subtitle: firstClick.current
                    ? String(localized: "settings.app.paneFirstClickFocus.subtitleOn", defaultValue: "When cmux is inactive, clicking a pane activates the window and focuses that pane in one click.")
                    : String(localized: "settings.app.paneFirstClickFocus.subtitleOff", defaultValue: "When cmux is inactive, the first click only activates the window. Click again to focus the pane.")
            ) {
                Toggle("", isOn: Binding(get: { firstClick.current }, set: { firstClick.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // File Drops
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:app:file-drops",
                String(localized: "settings.app.fileDrop.defaultBehavior", defaultValue: "File Drops"),
                subtitle: fileDropSubtitle(fileDrop.current),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { fileDrop.current }, set: { fileDrop.set($0) })) {
                    Text(String(localized: "settings.app.fileDrop.defaultBehavior.text", defaultValue: "Drop path text")).tag(FileDropDefaultBehavior.text)
                    Text(String(localized: "settings.app.fileDrop.defaultBehavior.preview", defaultValue: "Open file preview")).tag(FileDropDefaultBehavior.preview)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Preferred Editor
            SettingsCardRow(
                configurationReview: .json("app.preferredEditor"),
                String(localized: "settings.app.preferredEditor", defaultValue: "Open Files With"),
                subtitle: String(localized: "settings.app.preferredEditor.subtitle", defaultValue: "Command used when Cmd-click file previews are disabled or a file is unsupported. Leave empty for system default.")
            ) {
                TextField(
                    String(localized: "settings.app.preferredEditor.placeholder", defaultValue: "e.g. code, zed, subl"),
                    text: Binding(get: { preferredEditor.current }, set: { preferredEditor.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
            SettingsCardDivider()

            // Open Supported Files in cmux
            SettingsCardRow(
                configurationReview: .json("app.openSupportedFilesInCmux"),
                String(localized: "settings.app.openSupportedFilesInCmux", defaultValue: "Open Supported Files in cmux"),
                subtitle: String(localized: "settings.app.openSupportedFilesInCmux.subtitle", defaultValue: "Cmd-clicking readable files opens text, code, PDFs, images, audio, video, and Quick Look previews in cmux.")
            ) {
                Toggle("", isOn: Binding(get: { openSupported.current }, set: { openSupported.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Terminal Config (host action)
            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:app:terminal-config",
                String(localized: "settings.app.configWindow", defaultValue: "Terminal Config"),
                subtitle: String(localized: "settings.app.configWindow.subtitle", defaultValue: "Open the cmux terminal config and generated preview in one utility window."),
                controlWidth: Self.columnWidth
            ) {
                Button(String(localized: "settings.app.configWindow.openButton", defaultValue: "Open Config")) {
                    hostActions.openTerminalConfigWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            SettingsCardDivider()

            // Global Font Magnification
            SettingsCardRow(
                configurationReview: .json("app.globalFontMagnification"),
                String(localized: "settings.app.globalFontMagnification", defaultValue: "Global Font Magnification"),
                subtitle: globalFontMagnificationSubtitle
            ) {
                GlobalFontMagnificationControl(
                    percent: globalFontMagnification.current,
                    onChange: setGlobalFontMagnification
                )
            }
            SettingsCardDivider()

            // Open Markdown in cmux Viewer
            SettingsCardRow(
                configurationReview: .json("app.openMarkdownInCmuxViewer"),
                String(localized: "settings.app.openMarkdownInCmuxViewer", defaultValue: "Open Markdown in cmux Viewer"),
                subtitle: String(localized: "settings.app.openMarkdownInCmuxViewer.subtitle", defaultValue: "When supported file routing is on, Cmd-clicking Markdown files opens the rendered cmux markdown viewer instead of the generic file preview.")
            ) {
                Toggle("", isOn: Binding(get: { openMarkdown.current }, set: { openMarkdown.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Markdown Viewer Font Size
            SettingsCardRow(
                configurationReview: .json("markdown.fontSize"),
                String(localized: "settings.app.markdownFontSize", defaultValue: "Markdown Viewer Font Size"),
                subtitle: String(localized: "settings.app.markdownFontSize.subtitle", defaultValue: "Default body font size, in points, for newly opened markdown viewers. Zoom a viewer live with Cmd-+ / Cmd-- / Cmd-0."),
                controlWidth: Self.columnWidth
            ) {
                Stepper(
                    value: Binding(get: { markdownFontSize.current }, set: { markdownFontSize.set($0) }),
                    in: 8...96
                ) {
                    Text(verbatim: "\(markdownFontSize.current)")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMarkdownFontSizeStepper")
                .accessibilityLabel(
                    String(localized: "settings.app.markdownFontSize", defaultValue: "Markdown Viewer Font Size")
                )
            }
            SettingsCardDivider()

            // Markdown Viewer Max Width
            SettingsCardRow(
                configurationReview: .json("markdown.maxWidth"),
                String(localized: "settings.app.markdownMaxWidth", defaultValue: "Markdown Viewer Max Width"),
                subtitle: String(localized: "settings.app.markdownMaxWidth.subtitle", defaultValue: "Default maximum reading column width, in CSS pixels, for newly opened markdown viewers."),
                controlWidth: Self.columnWidth
            ) {
                Stepper(
                    value: Binding(get: { markdownMaxWidth.current }, set: { markdownMaxWidth.set($0) }),
                    in: 320...2400,
                    step: 20
                ) {
                    Text(verbatim: "\(markdownMaxWidth.current)")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMarkdownMaxWidthStepper")
                .accessibilityLabel(
                    String(localized: "settings.app.markdownMaxWidth", defaultValue: "Markdown Viewer Max Width")
                )
            }
            SettingsCardDivider()

            // Canvas Pane Gap
            SettingsCardRow(
                configurationReview: .json("canvas.paneGap"),
                String(localized: "settings.app.canvasPaneGap", defaultValue: "Canvas Pane Gap"),
                subtitle: String(localized: "settings.app.canvasPaneGap.subtitle", defaultValue: "Spacing between panes in the canvas layout, in points. Snapping, tidy, and new-pane placement all use this one gap."),
                controlWidth: Self.columnWidth
            ) {
                Stepper(
                    value: Binding(get: { canvasPaneGap.current }, set: { canvasPaneGap.set($0) }),
                    in: 0...64,
                    step: 2
                ) {
                    Text(verbatim: "\(canvasPaneGap.current)")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCanvasPaneGapStepper")
                .accessibilityLabel(
                    String(localized: "settings.app.canvasPaneGap", defaultValue: "Canvas Pane Gap")
                )
            }
            SettingsCardDivider()

            // Canvas Snapping
            SettingsCardRow(
                configurationReview: .json("canvas.snappingEnabled"),
                String(localized: "settings.app.canvasSnapping", defaultValue: "Canvas Snapping"),
                subtitle: String(localized: "settings.app.canvasSnapping.subtitle", defaultValue: "Snap pane drags and resizes to neighbor edges and the pane gap. Hold Command to suspend snapping for one gesture.")
            ) {
                Toggle("", isOn: Binding(get: { canvasSnapping.current }, set: { canvasSnapping.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsCanvasSnappingToggle")
            }
            SettingsCardDivider()

            // Markdown Viewer Font Family
            SettingsCardRow(
                configurationReview: .json("markdown.fontFamily"),
                String(localized: "settings.app.markdownFontFamily", defaultValue: "Markdown Viewer Font"),
                subtitle: String(localized: "settings.app.markdownFontFamily.subtitle", defaultValue: "Default body font family for newly opened markdown viewers. Leave empty for the system markdown font stack.")
            ) {
                TextField(
                    String(localized: "settings.app.markdownFontFamily.placeholder", defaultValue: "System"),
                    text: Binding(get: { markdownFontFamily.current }, set: { markdownFontFamily.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("SettingsMarkdownFontFamilyTextField")
            }
            SettingsCardDivider()

            // File Editor Word Wrap
            SettingsCardRow(
                configurationReview: .json("fileEditor.wordWrap"),
                String(localized: "settings.app.fileEditorWordWrap", defaultValue: "File Editor Word Wrap"),
                subtitle: String(localized: "settings.app.fileEditorWordWrap.subtitle", defaultValue: "Wrap long lines at the editor's right edge instead of scrolling horizontally. Applies to the plain-text file editor.")
            ) {
                Toggle("", isOn: Binding(get: { fileEditorWordWrap.current }, set: { fileEditorWordWrap.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsFileEditorWordWrapToggle")
            }
            SettingsCardDivider()

            // iMessage Mode
            SettingsCardRow(
                configurationReview: .json("app.iMessageMode"),
                String(localized: "settings.app.iMessageMode", defaultValue: "iMessage Mode"),
                subtitle: String(localized: "settings.app.iMessageMode.subtitle", defaultValue: "Move a workspace to the top and show the submitted message when you send an agent prompt.")
            ) {
                Toggle("", isOn: Binding(get: { iMessage.current }, set: { iMessage.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Reorder on Notification
            SettingsCardRow(
                configurationReview: .json("app.reorderOnNotification"),
                String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"),
                subtitle: String(localized: "settings.app.reorderOnNotification.subtitle", defaultValue: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions.")
            ) {
                Toggle("", isOn: Binding(get: { reorder.current }, set: { reorder.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Dock Badge
            SettingsCardRow(
                configurationReview: .json("notifications.dockBadge"),
                String(localized: "settings.app.dockBadge", defaultValue: "Dock Badge"),
                subtitle: String(localized: "settings.app.dockBadge.subtitle", defaultValue: "Show unread count on app icon (Dock and Cmd+Tab).")
            ) {
                Toggle("", isOn: Binding(get: { dockBadge.current }, set: { dockBadge.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Menu Bar Only
            SettingsCardRow(
                configurationReview: .json("app.menuBarOnly"),
                String(localized: "settings.app.menuBarOnly", defaultValue: "Menu Bar Only"),
                subtitle: String(localized: "settings.app.menuBarOnly.subtitle", defaultValue: "Hide the Dock icon and Cmd+Tab entry. Use the menu bar item to show cmux.")
            ) {
                Toggle("", isOn: Binding(get: { menuBarOnly.current }, set: { enabled in
                    if hostActions.setMenuBarOnly(enabled) {
                        menuBarOnly.acceptCommittedValue(enabled)
                    }
                }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsMenuBarOnlyToggle")
            }
            SettingsCardDivider()

            // Show in Menu Bar
            SettingsCardRow(
                configurationReview: .json("notifications.showInMenuBar"),
                String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar"),
                subtitle: String(localized: "settings.app.showInMenuBar.subtitle", defaultValue: "Keep cmux in the menu bar for unread notifications and quick actions.")
            ) {
                Toggle("", isOn: Binding(get: { showInMenuBar.current }, set: { showInMenuBar.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(menuBarOnly.current)
            SettingsCardDivider()

            // Unread Pane Ring
            SettingsCardRow(
                configurationReview: .json("notifications.unreadPaneRing"),
                String(localized: "settings.notifications.paneRing.title", defaultValue: "Unread Pane Ring"),
                subtitle: String(localized: "settings.notifications.paneRing.subtitle", defaultValue: "Show a blue ring around panes with unread notifications.")
            ) {
                Toggle("", isOn: Binding(get: { paneRing.current }, set: { paneRing.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Pane Flash
            SettingsCardRow(
                configurationReview: .json("notifications.paneFlash"),
                String(localized: "settings.notifications.paneFlash.title", defaultValue: "Pane Flash"),
                subtitle: String(localized: "settings.notifications.paneFlash.subtitle", defaultValue: "Briefly flash a blue outline when cmux highlights a pane.")
            ) {
                Toggle("", isOn: Binding(get: { paneFlash.current }, set: { paneFlash.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Agent: Needs Permission
            SettingsCardRow(
                configurationReview: .json("notifications.agentPermissionPrompt"),
                String(localized: "settings.notifications.agentPermissionPrompt.title", defaultValue: "Agent Needs Permission"),
                subtitle: String(localized: "settings.notifications.agentPermissionPrompt.subtitle", defaultValue: "Notify when an agent is blocked waiting for your permission to run a tool.")
            ) {
                Toggle("", isOn: Binding(get: { agentPermissionPrompt.current }, set: { agentPermissionPrompt.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Agent: Turn Complete
            SettingsCardRow(
                configurationReview: .json("notifications.agentTurnComplete"),
                String(localized: "settings.notifications.agentTurnComplete.title", defaultValue: "Agent Finished"),
                subtitle: String(localized: "settings.notifications.agentTurnComplete.subtitle", defaultValue: "When to notify that an agent finished. When idle waits until background tasks and scheduled wakeups drain.")
            ) {
                Picker("", selection: Binding(get: { agentTurnComplete.current }, set: { agentTurnComplete.set($0) })) {
                    Text(String(localized: "settings.notifications.agentTurnComplete.option.whenIdle", defaultValue: "When idle")).tag("whenIdle")
                    Text(String(localized: "settings.notifications.agentTurnComplete.option.always", defaultValue: "Always")).tag("always")
                    Text(String(localized: "settings.notifications.agentTurnComplete.option.never", defaultValue: "Never")).tag("never")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Agent: Idle Reminder
            SettingsCardRow(
                configurationReview: .json("notifications.agentIdleReminder"),
                String(localized: "settings.notifications.agentIdleReminder.title", defaultValue: "Agent Waiting for Input"),
                subtitle: String(localized: "settings.notifications.agentIdleReminder.subtitle", defaultValue: "Notify when an agent has been idle waiting for your input. Suppressed while background work is still running.")
            ) {
                Toggle("", isOn: Binding(get: { agentIdleReminder.current }, set: { agentIdleReminder.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }

            // Desktop Notifications
            SettingsCardDivider()
            DesktopNotificationsSettingsRow(
                state: desktopNotifications.current,
                requestAuthorization: { hostActions.requestNotificationAuthorization() },
                openSystemSettings: { hostActions.openSystemNotificationSettings() },
                sendTest: { hostActions.sendTestNotification() }
            )
            SettingsCardDivider()

            // Notification Sound — Picker over NSSound names with
            // Preview button. Custom-file path field appears when the
            // user selects "custom".
            notificationSoundRow(model: soundName)
            SettingsCardDivider()

            // Notification Command
            SettingsCardRow(
                configurationReview: .json("notifications.command"),
                String(localized: "settings.notifications.command", defaultValue: "Notification Command"),
                subtitle: String(localized: "settings.notifications.command.subtitle", defaultValue: "Run a shell command when a notification arrives. $CMUX_NOTIFICATION_TITLE, $CMUX_NOTIFICATION_SUBTITLE, $CMUX_NOTIFICATION_BODY are set.")
            ) {
                TextField(
                    String(localized: "settings.notifications.command.placeholder", defaultValue: "say \"done\""),
                    text: Binding(get: { soundCommand.current }, set: { soundCommand.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
            SettingsCardDivider()

            // Telemetry
            SettingsCardRow(
                configurationReview: .json("app.sendAnonymousTelemetry"),
                String(localized: "settings.app.telemetry", defaultValue: "Send anonymous telemetry"),
                subtitle: (telemetryAtAppear != nil && telemetry.current != telemetryAtAppear)
                    ? String(localized: "settings.app.telemetry.subtitleChanged", defaultValue: "Change takes effect on next launch.")
                    : String(localized: "settings.app.telemetry.subtitle", defaultValue: "Share anonymized crash and usage data to help improve cmux.")
            ) {
                Toggle("", isOn: Binding(get: { telemetry.current }, set: { telemetry.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Warn Before Quit
            SettingsCardRow(
                configurationReview: .json("app.confirmQuit", "app.warnBeforeQuit"),
                String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"),
                subtitle: confirmQuitSubtitle(confirmQuit.current),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { confirmQuit.current }, set: { confirmQuit.set($0) })) {
                    // Labels mirror legacy QuitConfirmationMode.localizedSettingsTitle.
                    Text(String(localized: "settings.app.confirmQuit.always", defaultValue: "Always")).tag(ConfirmQuitMode.always)
                    Text(String(localized: "settings.app.confirmQuit.dirtyOnly", defaultValue: "Dirty Only")).tag(ConfirmQuitMode.dirtyOnly)
                    Text(String(localized: "settings.app.confirmQuit.never", defaultValue: "Never")).tag(ConfirmQuitMode.never)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            SettingsCardDivider()

            // Warn Before Closing Tab
            SettingsCardRow(
                configurationReview: .json("app.warnBeforeClosingTab"),
                String(localized: "settings.app.warnBeforeClosingTab", defaultValue: "Warn Before Closing Tab"),
                subtitle: warnCloseTab.current
                    ? String(localized: "settings.app.warnBeforeClosingTab.subtitleOn", defaultValue: "Show a confirmation before closing a tab.")
                    : String(localized: "settings.app.warnBeforeClosingTab.subtitleOff", defaultValue: "Tabs close immediately without confirmation.")
            ) {
                Toggle("", isOn: Binding(get: { warnCloseTab.current }, set: { warnCloseTab.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Warn Before Tab Close Button
            SettingsCardRow(
                configurationReview: .json("app.warnBeforeClosingTabXButton"),
                String(localized: "settings.app.warnBeforeClosingTabXButton", defaultValue: "Warn Before Tab Close Button"),
                subtitle: warnCloseXSubtitle(hideCloseButton: hideCloseButton.current, warnEnabled: warnCloseX.current)
            ) {
                Toggle("", isOn: Binding(get: { warnCloseX.current }, set: { warnCloseX.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(hideCloseButton.current)
            }
            SettingsCardDivider()

            // Hide Tab Close Button
            SettingsCardRow(
                configurationReview: .json("app.hideTabCloseButton"),
                String(localized: "settings.app.hideTabCloseButton", defaultValue: "Hide Tab Close Button"),
                subtitle: hideCloseButton.current
                    ? String(localized: "settings.app.hideTabCloseButton.subtitleOn", defaultValue: "Tab close buttons are hidden.")
                    : String(localized: "settings.app.hideTabCloseButton.subtitleOff", defaultValue: "Tab close buttons appear on hover and on the active tab.")
            ) {
                Toggle("", isOn: Binding(get: { hideCloseButton.current }, set: { hideCloseButton.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Rename Selects Existing Name
            SettingsCardRow(
                configurationReview: .json("app.renameSelectsExistingName"),
                String(localized: "settings.app.renameSelectsName", defaultValue: "Rename Selects Existing Name"),
                subtitle: renameSelects.current
                    ? String(localized: "settings.app.renameSelectsName.subtitleOn", defaultValue: "Command Palette rename starts with all text selected.")
                    : String(localized: "settings.app.renameSelectsName.subtitleOff", defaultValue: "Command Palette rename keeps the caret at the end.")
            ) {
                Toggle("", isOn: Binding(get: { renameSelects.current }, set: { renameSelects.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Command Palette Searches All Surfaces
            SettingsCardRow(
                configurationReview: .json("app.commandPaletteSearchesAllSurfaces"),
                String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces"),
                subtitle: paletteAllSurfaces.current
                    ? String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOn", defaultValue: "Cmd+P also matches panel surfaces across workspaces.")
                    : String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOff", defaultValue: "Cmd+P matches workspace rows only.")
            ) {
                Toggle("", isOn: Binding(get: { paletteAllSurfaces.current }, set: { paletteAllSurfaces.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("CommandPaletteSearchAllSurfacesToggle")
            }
        }
    }

    /// Standard macOS notification sound names plus cmux-specific
    /// sentinels for default / none / custom-file. Matches the
    /// legacy `NotificationSoundSettings.systemSounds` list shape
    /// (order, labels, and the `custom_file` sentinel value).
    private static let customSoundFileValue = "custom_file"
    private static let systemSoundOptions: [(value: String, label: String)] = [
        ("default", "Default"),
        ("Basso", "Basso"),
        ("Blow", "Blow"),
        ("Bottle", "Bottle"),
        ("Frog", "Frog"),
        ("Funk", "Funk"),
        ("Glass", "Glass"),
        ("Hero", "Hero"),
        ("Morse", "Morse"),
        ("Ping", "Ping"),
        ("Pop", "Pop"),
        ("Purr", "Purr"),
        ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"),
        ("Tink", "Tink"),
        (customSoundFileValue, "Custom File..."),
        ("none", "None"),
    ]

    @ViewBuilder
    private func notificationSoundRow(model: DefaultsValueModel<String>) -> some View {
        let customFile = customSoundFile
        SettingsCardRow(
            configurationReview: .json("notifications.sound", "notifications.customSoundFilePath"),
            String(localized: "settings.notifications.sound.title", defaultValue: "Notification Sound"),
            subtitle: String(localized: "settings.notifications.sound.subtitle", defaultValue: "Sound played when a notification arrives."),
            controlWidth: Self.notificationSoundControlWidth
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { model.current }, set: { model.set($0) })) {
                        ForEach(Self.systemSoundOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    Button {
                        hostActions.previewNotificationSound(value: model.current, customFilePath: customFile.current)
                    } label: {
                        Image(systemName: "play.fill")
                            .cmuxFont(size: 9)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canPreviewNotificationSound(soundValue: model.current, customFilePath: customFile.current))
                }
                if model.current == Self.customSoundFileValue {
                    HStack(spacing: 6) {
                        // Legacy AppSection always renders the file
                        // display name slot, with a "No file selected"
                        // fallback when the path is empty.
                        Text(customSoundFileDisplayName(path: customFile.current))
                            .cmuxFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 170, alignment: .trailing)
                        Button(String(localized: "settings.notifications.sound.custom.choose.button", defaultValue: "Choose...")) {
                            chooseCustomNotificationSound(into: customFile)
                        }
                        .controlSize(.small)
                        Button(String(localized: "settings.notifications.sound.custom.clear.button", defaultValue: "Clear")) {
                            customFile.reset()
                        }
                        .controlSize(.small)
                        .disabled(customFile.current.isEmpty)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func chooseCustomNotificationSound(into model: DefaultsValueModel<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.customNotificationSoundAllowedContentTypes
        panel.title = String(localized: "settings.notifications.sound.custom.panelTitle", defaultValue: "Choose Notification Sound")
        if panel.runModal() == .OK, let url = panel.url {
            model.set(url.path)
        }
    }

    private func languageDisplayName(_ language: AppLanguage) -> String {
        // Mirrors legacy AppLanguage.displayName: native name plus an
        // English suffix in parentheses, except for English and
        // Portuguese (Brasil) which already carry the locale name.
        switch language {
        case .system: return String(localized: "language.system", defaultValue: "System")
        case .en: return "English"
        case .ar: return "\u{200E}العربية (Arabic)"
        case .bs: return "Bosanski (Bosnian)"
        case .zhHans: return "简体中文 (Chinese Simplified)"
        case .zhHant: return "繁體中文 (Chinese Traditional)"
        case .da: return "Dansk (Danish)"
        case .de: return "Deutsch (German)"
        case .es: return "Español (Spanish)"
        case .fr: return "Français (French)"
        case .it: return "Italiano (Italian)"
        case .ja: return "日本語 (Japanese)"
        case .ko: return "한국어 (Korean)"
        case .nb: return "Norsk (Norwegian)"
        case .pl: return "Polski (Polish)"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский (Russian)"
        case .th: return "ไทย (Thai)"
        case .tr: return "Türkçe (Turkish)"
        case .vi: return "Tiếng Việt (Vietnamese)"
        }
    }

    private func workspacePlacementSubtitle(_ placement: WorkspacePlacement) -> String {
        // Mirrors legacy NewWorkspacePlacement.description verbatim
        // (Sources/TabManager.swift, "workspace.placement.*.description").
        switch placement {
        case .top:
            return String(
                localized: "workspace.placement.top.description",
                defaultValue: "Insert new workspaces at the top of the list."
            )
        case .afterCurrent:
            return String(
                localized: "workspace.placement.afterCurrent.description",
                defaultValue: "Insert new workspaces directly after the active workspace."
            )
        case .end:
            return String(
                localized: "workspace.placement.end.description",
                defaultValue: "Append new workspaces to the bottom of the list."
            )
        }
    }

    private func fileDropSubtitle(_ behavior: FileDropDefaultBehavior) -> String {
        switch behavior {
        case .text:
            return String(
                localized: "settings.app.fileDrop.defaultBehavior.text.subtitle",
                defaultValue: "Over terminals and editors, dragging files inserts shell-escaped paths. Hold Shift to open a file preview or split."
            )
        case .preview:
            return String(
                localized: "settings.app.fileDrop.defaultBehavior.preview.subtitle",
                defaultValue: "Dragging files opens previews or split panes. Hold Shift over terminals and editors to insert path text."
            )
        }
    }

    private func confirmQuitSubtitle(_ mode: ConfirmQuitMode) -> String {
        // Mirrors legacy confirmQuitModeSubtitle keys/text.
        switch mode {
        case .always: return String(localized: "settings.app.warnBeforeQuit.subtitleOn", defaultValue: "Show a confirmation before quitting with Cmd+Q.")
        case .dirtyOnly: return String(localized: "settings.app.confirmQuit.subtitleDirtyOnly", defaultValue: "Show a confirmation only when a workspace needs close confirmation.")
        case .never: return String(localized: "settings.app.warnBeforeQuit.subtitleOff", defaultValue: "Cmd+Q quits immediately without confirmation.")
        }
    }

    /// Mirrors legacy `notificationSoundCustomFileDisplayName`.
    private func customSoundFileDisplayName(path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(
                localized: "settings.notifications.sound.custom.file.none",
                defaultValue: "No file selected"
            )
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    /// Mirrors legacy `canPreviewNotificationSound`. Custom-file mode
    /// can only preview when a path is present.
    private func canPreviewNotificationSound(soundValue: String, customFilePath: String) -> Bool {
        switch soundValue {
        case "none":
            return false
        case Self.customSoundFileValue:
            return !customFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    private func warnCloseXSubtitle(hideCloseButton: Bool, warnEnabled: Bool) -> String {
        // Mirrors legacy warnBeforeClosingTabXButtonSubtitle: hidden override
        // takes priority, then on/off wording.
        if hideCloseButton {
            return String(
                localized: "settings.app.warnBeforeClosingTabXButton.subtitleHidden",
                defaultValue: "Tab close buttons are hidden, so this warning is inactive."
            )
        }
        if warnEnabled {
            return String(
                localized: "settings.app.warnBeforeClosingTabXButton.subtitleOn",
                defaultValue: "The tab close button asks for confirmation before closing."
            )
        }
        return String(
            localized: "settings.app.warnBeforeClosingTabXButton.subtitleOff",
            defaultValue: "The tab close button closes tabs immediately."
        )
    }
}
