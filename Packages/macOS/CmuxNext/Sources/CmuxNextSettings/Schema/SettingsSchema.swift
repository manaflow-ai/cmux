import CmuxNextActions
public import CmuxNextDesign
public import CoreGraphics

/// Every cmux.json setting the Settings window edits, in display order. A
/// new setting is one descriptor here (plus its parser): the window, write
/// validation and the palette's Toggle Setting pick it up, and
/// `SettingsSchemaTests` fails until the parser accepts every value the
/// descriptor allows and rejects the rest.
public nonisolated enum SettingsSchema {
    /// Built once per run: each descriptor looks its texts up in the strings bundle, and launch
    /// reads it twice before the first window (about 20 ms in all on a cold launch, bd cx-z9kz0).
    public static let all: [SettingDescriptor] = {
        let next = GeneralSettingsSchema.history + GeneralSettingsSchema.window + TabSettingsSchema.descriptors + GeneralSettingsSchema.quitting + GeneralSettingsSchema.columns
            + ShortcutHintsSettingsSchema.descriptors + UpdateSettingsSchema.descriptors + UpdateSettingsSchema.announcements
            + MachineSettingsSchema.computerUse + MachineSettingsSchema.freeModel + SessionSettingsSchema.descriptors + SessionSettingsSchema.phoneDescriptors + MachineColorsSettingsSchema.descriptors + MachineSettingsSchema.sshLinks + MachineSettingsSchema.cloud + SubsessionSettingsSchema.descriptors + AgentGuidanceSettingsSchema.descriptors + AgentRetrySettingsSchema.descriptors + AgentCacheSettingsSchema.descriptors + TrustSettingsSchema.descriptors + MachineSettingsSchema.mobile + GeneralSettingsSchema.layout
            + GeneralSettingsSchema.workspaceList + GeneralSettingsSchema.palette
            + ChatSettingsSchema.descriptors + PickerSettingsSchema.descriptors + ScreenshotsSettingsSchema.descriptors + AutoArchiveSettingsSchema.descriptors + WorkspaceHibernationSettingsSchema.descriptors + TaskSettingsSchema.descriptors + appearance + TerminalSettingsSchema.descriptors + EditorSettingsSchema.descriptors
            + SidebarSettingsSchema.sidebar + HoverCardSettingsSchema.descriptors + NowPlayingSettingsSchema.descriptors + NowPlayingSettingsSchema.newTabDescriptors + NowPlayingSettingsSchema.pictureInPictureDescriptors + NewTabWidgetSettingsSchema.descriptors + ColorTransitionSettingsSchema.descriptors + WorkspaceRowSetting.descriptors + BrowserSettingsSchema.descriptors + HomeSettingsSchema.descriptors + ChiefReactionSettingsSchema.descriptors + ChiefPermissionSettingsSchema.descriptors + ChiefRoutingSettingsSchema.descriptors + ChiefSidebarSettingsSchema.descriptors
            + NotificationSettingsSchema.dismissalDescriptors + NotificationSettingsSchema.bannerDescriptors + NotificationSettingsSchema.feedMirrorDescriptors
            + NotificationSettingsSchema.attentionDescriptors + NotificationSettingsSchema.mutedWorkspacesDescriptors + NotificationSettingsSchema.soundDescriptors
            + LabsSettingsSchema.descriptors + FeedSettingsSchema.descriptors + AgentPaneSettingsSchema.descriptors
            + AgentPaneEditedFilesSettingsSchema.descriptors + AgentPaneComposerSettingsSchema.descriptors + AgentPaneZoomSettingsSchema.descriptors
            + AgentDefaultsSettingsSchema.descriptors + HangReportsSettingsSchema.descriptors + DeveloperToolsSettingsSchema.descriptors
            + DeveloperToolsSettingsSchema.internalDeveloperMode
            + MachineSettingsSchema.macScreen + MachineSettingsSchema.macScreenDebug + MachineSettingsSchema.remote
            + MachineSettingsSchema.deviceHub + GeneralSettingsSchema.menus + MachineSettingsSchema.imessage
        return next.map { sharedWithBrowser.contains($0.id) ? $0.consumed(by: [.cmuxNext, .cmuxBrowser]) : $0 }
            + BrowserAppSettingsSchema.descriptors
    }()

    // `sharedWithBrowser`, `keptOnResetAll`: schemas/settings/source/row-facts.json
    // (SettingsSchema+RowFacts.generated.swift).

    /// The descriptors cmux-next shows in one section, in order (keys only cmux-browser reads and
    /// page-hidden keys stay out).
    public static func settings(in section: SettingsSection) -> [SettingDescriptor] {
        all.filter { $0.section == section && $0.isShownOnSettingsPage }
    }

    /// The descriptor for a dotted key or key path.
    public static func descriptor(for path: [String]) -> SettingDescriptor? {
        all.first { $0.path == path }
    }

    // MARK: Appearance

    static var appearance: [SettingDescriptor] {
        AppearanceSettingsSchema.iconTheme + AppearanceSettingsSchema.appTheme + AppearanceSettingsSchema.windowBackground + AppearanceSettingsSchema.tuning
            + AppearanceSettingsSchema.look + AppearanceSettingsSchema.chromeStyle + AppearanceSettingsSchema.lookMotion
            + AppearanceSettingsSchema.panes + AppearanceSettingsSchema.focusRing + MotionSettingsSchema.descriptors + SurfaceSettingsSchema.descriptors + StatusIndicatorSettingsSchema.descriptors
            + DiffViewerSettingsSchema.descriptors + MarkdownViewerSettingsSchema.descriptors + AgentPaneDisplaySettingsSchema.descriptors
    }

    static func points(_ range: ClosedRange<CGFloat>, step: Double, placeholder: Double? = nil) -> SettingNumber {
        SettingNumber(Double(range.lowerBound)...Double(range.upperBound), step: step, unit: .points, placeholder: placeholder)
    }
}
