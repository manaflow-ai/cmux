import AppKit
import CmuxAppKitSupportUI
import CmuxCloud
import CmuxProductAnalytics
import CmuxFoundation
import CmuxSettingsUI
import CmuxSidebar
import CmuxSidebarProviderKit
import CmuxUpdater
import CmuxWorkspaces
import SwiftUI

/// Footer debug controls and empty-area drop targets for the vertical tabs sidebar, extracted from `ContentView.swift`, which sits at its file-length budget.
struct SidebarFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterIconButtonStyleBody(configuration: configuration)
    }
}

struct SidebarFooterCircularIconStyle: Equatable {
    static let standard = SidebarFooterCircularIconStyle(
        pointSize: 14,
        weight: .regular
    )

    let pointSize: CGFloat
    let weight: Font.Weight

    func resized(to pointSize: CGFloat) -> SidebarFooterCircularIconStyle {
        SidebarFooterCircularIconStyle(pointSize: pointSize, weight: weight)
    }
}

enum SidebarFooterButtonMetrics {
    static let buttonSize: CGFloat = 22
    static let accountAndHelpVisualSize = SidebarFooterCircularIconStyle.standard.pointSize
    static let profilePictureSize = accountAndHelpVisualSize
    static let profileIconSize = accountAndHelpVisualSize
    static let mobileIconSize: CGFloat = 12
    static let helpIconSize = accountAndHelpVisualSize
    static let cloudIconSize = accountAndHelpVisualSize
    /// The cloud glyph is 2.5 pt wider than the 14 pt account and help glyphs,
    /// so half that keeps the visible gap after Help equal to the one before it.
    static let cloudLeadingInset: CGFloat = 1.5
    /// The labeled Cloud entry: footer-height capsule, label one step under
    /// the 13 pt workspace rows so it reads as chrome, count at the same size
    /// but quieter (Linear's "Priority 4" chip weighting).
    static let cloudLabelFontSize: CGFloat = 12
    static let cloudLabelSpacing: CGFloat = 4
    static let cloudLabelLeadingPadding: CGFloat = 4
    static let cloudLabelTrailingPadding: CGFloat = 6
    static let cloudCountOpacity = 0.7
    /// A 6 pt status dot tucked on the cloud's upper right, like the unread
    /// and attention dots on workspace rows.
    static let cloudMarkSize: CGFloat = 6
    static let cloudMarkOffset = CGSize(width: 2, height: -1)
    static let hoverOpacity = 0.08
}

enum SidebarAccountButtonVisual: Equatable {
    case profilePicture
    case profileIcon(systemName: String)
}

struct SidebarAccountButtonPresentation: Equatable {
    static let defaultProfileIconSystemName = "person.crop.circle"

    let visual: SidebarAccountButtonVisual
    let size: CGFloat

    static func resolve(
        isSignedIn: Bool,
        prefersProfileIcon: Bool,
        hasProfilePicture: Bool = false
    ) -> SidebarAccountButtonPresentation {
        if isSignedIn, hasProfilePicture, !prefersProfileIcon {
            return SidebarAccountButtonPresentation(
                visual: .profilePicture,
                size: SidebarFooterButtonMetrics.profilePictureSize
            )
        }
        return SidebarAccountButtonPresentation(
            visual: .profileIcon(systemName: defaultProfileIconSystemName),
            size: SidebarFooterButtonMetrics.profileIconSize
        )
    }

    var showsProfilePicture: Bool {
        visual == .profilePicture
    }
}

enum SidebarFooterControl: CaseIterable, Equatable {
    case account
    case mobileConnect
    case help
    case cloud
    case shortcutDiscovery
    case upgrade
    case extensions
    case update
}

enum SidebarFooterPresentationPolicy {
    static func isVisible(
        _ control: SidebarFooterControl,
        presentationMode: WorkspacePresentationModeSettings.Mode
    ) -> Bool {
        presentationMode != .minimal || control == .upgrade
    }

    static func isUpgradeVisible(
        isProActive: Bool,
        isProStatusKnown: Bool = true
    ) -> Bool {
        isProStatusKnown && !isProActive
    }
}

#if DEBUG
enum SidebarFooterIconButtonDebugSettings {
    static let hoverOpacityKey = "debug.sidebarFooterIconButton.hoverOpacity"
    static let defaultHoverOpacity = SidebarFooterButtonMetrics.hoverOpacity
}

enum SidebarFooterProfileIconDebugChoice: String, CaseIterable, Identifiable {
    case outline = "person"
    case filled = "person.fill"
    case cropCircle = "person.crop.circle"
    case filledCropCircle = "person.crop.circle.fill"

    var id: String { rawValue }
}

enum SidebarFooterProfileIconDebugSettings {
    static let iconKey = "debug.sidebarFooterProfileIcon.symbol.v3"
    static let sizeKey = "debug.sidebarFooterProfileIcon.size"
    static let defaultIcon = SidebarFooterProfileIconDebugChoice.cropCircle
    static let defaultSize = Double(SidebarFooterButtonMetrics.profileIconSize)
}

enum SidebarFooterProfileDisplayDebugChoice: String, CaseIterable, Identifiable {
    case picture
    case icon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .picture:
            String(
                localized: "debug.sidebarFooterIconBalance.profileDisplay.picture",
                defaultValue: "Picture"
            )
        case .icon:
            String(
                localized: "debug.sidebarFooterIconBalance.profileDisplay.icon",
                defaultValue: "Icon"
            )
        }
    }
}

enum SidebarFooterProfileDisplayDebugSettings {
    static let displayKey = "debug.sidebarFooterProfile.display"
    static let defaultDisplay = SidebarFooterProfileDisplayDebugChoice.picture
}

enum SidebarFooterMobileIconDebugSettings {
    static let sizeKey = "debug.sidebarFooterMobileIcon.size"
    static let defaultSize = Double(SidebarFooterButtonMetrics.mobileIconSize)
}

enum SidebarFooterHelpIconDebugWeight: String, CaseIterable, Identifiable {
    case regular
    case medium
    case semibold

    var id: String { rawValue }

    var fontWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    var displayName: String {
        switch self {
        case .regular:
            String(localized: "debug.sidebarFooterIconBalance.weight.regular", defaultValue: "Regular")
        case .medium:
            String(localized: "debug.sidebarFooterIconBalance.weight.medium", defaultValue: "Medium")
        case .semibold:
            String(localized: "debug.sidebarFooterIconBalance.weight.semibold", defaultValue: "Semibold")
        }
    }
}

enum SidebarFooterHelpIconDebugChoice: String, CaseIterable, Identifiable {
    case bare = "questionmark"
    case circle = "questionmark.circle"
    case filledCircle = "questionmark.circle.fill"

    var id: String { rawValue }
}

enum SidebarFooterHelpIconDebugSettings {
    static let sizeKey = "debug.sidebarFooterHelpIcon.size"
    static let weightKey = "debug.sidebarFooterHelpIcon.weight"
    static let iconKey = "debug.sidebarFooterHelpIcon.symbol"
    static let defaultSize = Double(SidebarFooterButtonMetrics.helpIconSize)
    static let defaultWeight = SidebarFooterHelpIconDebugWeight.regular
    static let defaultIcon = SidebarFooterHelpIconDebugChoice.circle
}
#endif

struct SidebarFooterCircularIcon: View {
    let systemName: String
    let style: SidebarFooterCircularIconStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sidebarReadabilityBackdrop) private var readabilityBackdrop

    var body: some View {
        CmuxSystemSymbolImage(
            systemName: systemName,
            pointSize: style.pointSize,
            weight: style.weight,
            tint: SidebarAppearanceColorResolver().readableSecondary(for: colorScheme, over: readabilityBackdrop)
        )
    }
}

struct SidebarFooterHelpIcon: View {
    let style: SidebarFooterCircularIconStyle
#if DEBUG
    @AppStorage(SidebarFooterHelpIconDebugSettings.iconKey)
    private var debugIcon = SidebarFooterHelpIconDebugSettings.defaultIcon.rawValue
#endif

    init(pointSize: CGFloat, weight: Font.Weight) {
        style = SidebarFooterCircularIconStyle(pointSize: pointSize, weight: weight)
    }

    private var systemName: String {
#if DEBUG
        SidebarFooterHelpIconDebugChoice(rawValue: debugIcon)?.rawValue
            ?? SidebarFooterHelpIconDebugSettings.defaultIcon.rawValue
#else
        "questionmark.circle"
#endif
    }

    var body: some View {
        SidebarFooterCircularIcon(systemName: systemName, style: style)
    }
}

struct SidebarAccountAvatar: View {
    let avatarURL: URL?
    let displayName: String
    let email: String
    let isSignedIn: Bool
    let size: CGFloat
#if DEBUG
    @AppStorage(SidebarFooterProfileIconDebugSettings.iconKey)
    private var debugIcon = SidebarFooterProfileIconDebugSettings.defaultIcon.rawValue
#endif

    private var signedOutSystemName: String {
#if DEBUG
        SidebarFooterProfileIconDebugChoice(rawValue: debugIcon)?.rawValue
            ?? SidebarFooterProfileIconDebugSettings.defaultIcon.rawValue
#else
        SidebarAccountButtonPresentation.defaultProfileIconSystemName
#endif
    }

    var body: some View {
        if isSignedIn {
            StackAccountAvatarView(
                avatarURL: avatarURL,
                displayName: displayName,
                email: email,
                size: size,
                loadingSystemName: signedOutSystemName
            )
        } else {
            SidebarFooterCircularIcon(
                systemName: signedOutSystemName,
                style: SidebarFooterCircularIconStyle.standard.resized(to: size)
            )
            .frame(width: size, height: size, alignment: .center)
        }
    }

}

struct SidebarMobileConnectButton: View {
    @EnvironmentObject private var tabManager: TabManager
    private let title = String(localized: "command.mobileConnect.title", defaultValue: "Open Mobile Pairing")
#if DEBUG
    @AppStorage(SidebarFooterMobileIconDebugSettings.sizeKey)
    private var debugIconSize = SidebarFooterMobileIconDebugSettings.defaultSize
#endif

    private var iconSize: CGFloat {
#if DEBUG
        CGFloat(debugIconSize)
#else
        SidebarFooterButtonMetrics.mobileIconSize
#endif
    }

    var body: some View {
        // Hidden under a managed remote-control disable: pairing cannot open
        // (chokepoint in performMobileConnectWorkspaceAction), so showing the
        // button would be a dead affordance.
        if MobileRemoteControlPolicy.isEnabled {
            Button {
                _ = AppDelegate.shared?.performMobileConnectWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "sidebar.mobileConnect"
                )
            } label: {
                CmuxSystemSymbolImage(systemName: "iphone", pointSize: iconSize, weight: .medium, tint: .secondary)
                    .frame(
                        width: SidebarFooterButtonMetrics.buttonSize,
                        height: SidebarFooterButtonMetrics.buttonSize
                    )
            }
            .buttonStyle(SidebarFooterIconButtonStyle())
            .frame(
                width: SidebarFooterButtonMetrics.buttonSize,
                height: SidebarFooterButtonMetrics.buttonSize
            )
            .safeHelp(title)
            .hintableAccessibilityLabel(title)
            .accessibilityIdentifier("SidebarMobileConnectButton")
        }
    }
}

/// Opens Cloud Machines in the right sidebar, introducing Cloud first while
/// it is off. Follows the "Show Cloud and Device Icons in Sidebar" setting and
/// stays hidden when managed policy disables Cloud.
///
/// Labeled ("Cloud", plus the running count) so the entry point names itself;
/// it falls back to the bare glyph when the footer is too narrow. The status
/// comes from ``SidebarCloudButtonPresentation``.
struct SidebarCloudButton: View {
    @LiveSetting(\.sidebar.showCloudDeviceIcons) private var showsCloudDeviceIcons
    @AppStorage(SidebarCloudButtonPresentation.introductionSeenKey) private var hasOpenedCloud = false
    @State private var anchorView: NSView?
    private let title = String(localized: "sidebar.cloud.button", defaultValue: "Cloud")

    var body: some View {
        if showsCloudDeviceIcons, CloudMachinesFeature.isAvailable {
            // Reads only the catalog's `machines`, reduced to a small value.
            let presentation = SidebarCloudButtonPresentation.resolve(
                machines: SurfaceCatalog.shared.machines.values,
                hasOpenedCloud: hasOpenedCloud
            )
            Button {
                SidebarCloudButtonPresentation.recordCloudOpened()
                AppDelegate.shared?.performSidebarCloudButtonAction(preferredWindow: anchorView?.window)
            } label: {
                SidebarCloudButtonLabel(title: title, presentation: presentation)
            }
            .buttonStyle(SidebarFooterIconButtonStyle())
            .background(TitlebarControlAnchorView { anchorView = $0 })
            .safeHelp(presentation.help)
            .hintableAccessibilityLabel(title)
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityIdentifier("SidebarCloudButton")
            .padding(.leading, SidebarFooterButtonMetrics.cloudLeadingInset)
            .onAppear { ProductAnalytics.app.track(.cloudButtonShown) }
        }
    }
}

/// The Cloud entry's face: glyph, word and quiet count in a footer-height
/// capsule, or the glyph alone when space is short. One status mark rides on
/// the glyph in either form.
struct SidebarCloudButtonLabel: View {
    let title: String
    let presentation: SidebarCloudButtonPresentation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sidebarReadabilityBackdrop) private var readabilityBackdrop
    @Environment(\.cmuxAccentColor) private var cmuxAccent

    private var tint: Color {
        SidebarAppearanceColorResolver().readableSecondary(for: colorScheme, over: readabilityBackdrop)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SidebarFooterButtonMetrics.cloudLabelSpacing) {
                glyph
                Text(title)
                    .cmuxFont(size: SidebarFooterButtonMetrics.cloudLabelFontSize, weight: .medium)
                    .foregroundStyle(tint)
                if let count = presentation.countText {
                    Text(count)
                        .cmuxFont(size: SidebarFooterButtonMetrics.cloudLabelFontSize, monospacedDigit: true)
                        .foregroundStyle(tint.opacity(SidebarFooterButtonMetrics.cloudCountOpacity))
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, SidebarFooterButtonMetrics.cloudLabelLeadingPadding)
            .padding(.trailing, SidebarFooterButtonMetrics.cloudLabelTrailingPadding)
            .frame(height: SidebarFooterButtonMetrics.buttonSize)

            glyph
                .frame(width: SidebarFooterButtonMetrics.buttonSize, height: SidebarFooterButtonMetrics.buttonSize)
        }
        .contentShape(Rectangle())
    }

    private var glyph: some View {
        SidebarFooterCircularIcon(
            systemName: "cloud",
            style: SidebarFooterCircularIconStyle.standard.resized(to: SidebarFooterButtonMetrics.cloudIconSize)
        )
        .overlay(alignment: .topTrailing) {
            if let color = markColor {
                Circle()
                    .fill(color)
                    .frame(width: SidebarFooterButtonMetrics.cloudMarkSize, height: SidebarFooterButtonMetrics.cloudMarkSize)
                    .offset(x: SidebarFooterButtonMetrics.cloudMarkOffset.width, y: SidebarFooterButtonMetrics.cloudMarkOffset.height)
                    .accessibilityHidden(true)
            }
        }
    }

    private var markColor: Color? {
        switch presentation.mark {
        case .quiet: nil
        case .attention: Color(nsColor: .systemOrange)
        case .introduction: cmuxAccent.color
        }
    }
}

private struct SidebarFooterIconButtonStyleBody: View {
    let configuration: SidebarFooterIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
#if DEBUG
    @AppStorage(SidebarFooterIconButtonDebugSettings.hoverOpacityKey)
    private var debugHoverOpacity = SidebarFooterIconButtonDebugSettings.defaultHoverOpacity
#endif

    private var hoverOpacity: Double {
#if DEBUG
        debugHoverOpacity
#else
        SidebarFooterButtonMetrics.hoverOpacity
#endif
    }

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return hoverOpacity }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .chromeRevealAnimation(isVisible: isHovered, fadeOut: .easeOut(duration: 0.12))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#if DEBUG
struct SidebarDevFooter: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor
    let onSendFeedback: () -> Void
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, modifierKeyMonitor: modifierKeyMonitor, onSendFeedback: onSendFeedback)
            if showSidebarDevBuildBanner {
                Text(String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD"))
                    .cmuxFont(size: 11, weight: .semibold)
                    .foregroundColor(.red)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }
}
#endif

struct SidebarEmptyArea: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    @EnvironmentObject var tabManager: TabManager
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    // Value snapshot + closure bundles instead of an @Observable store
    // reference (snapshot-boundary rule).
    let topDropIndicatorVisible: Bool
    var tabDropDelegate: SidebarTabDropDelegate? = nil
    let bonsplitDropIndicator: Binding<SidebarDropIndicator?>
    var expandsVertically = true
    var minimumHeight: CGFloat? = nil

    var body: some View {
        dropTarget
            .overlay {
                SidebarBonsplitTabNewWorkspaceDropOverlay(
                    tabManager: tabManager,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dropIndicator: bonsplitDropIndicator
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                if topDropIndicatorVisible {
                    Rectangle()
                        .fill(cmuxAccent.color)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    @ViewBuilder
    private var dropTarget: some View {
        let base = hitTarget
            .onTapGesture(count: 2) {
                // Both sidebar implementations (this one and the AppKit table)
                // share one entry point so a configured `ui.newWorkspace.action`,
                // and the remote-tmux mirror routing, behave identically here and
                // for the `+` button.
                if let appDelegate = AppDelegate.shared {
                    appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: tabManager)
                } else {
                    tabManager.addWorkspaceIfActive(placementOverride: .end)
                }
                if let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            }
        if let tabDropDelegate {
            base
                .sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager: tabManager)
                .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegate)
        } else {
            base
                .sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager: tabManager)
        }
    }

    @ViewBuilder
    private var hitTarget: some View {
        if expandsVertically {
            // This full-height background extends behind the rows. Keep it
            // SwiftUI-only so native hit testing cannot steal row presses;
            // the AppKit table and clip view own native-sidebar window drags.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: minimumHeight ?? 0)
                .contentShape(Rectangle())
        }
    }
}

private extension View {
    func sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager: TabManager) -> some View {
        contextMenu {
            let newWorkspaceGroupShortcut = KeyboardShortcutSettings.shortcut(for: .newWorkspaceGroup)
            let newWorkspaceGroupLabel = String(
                localized: "contextMenu.workspaceGroup.newEmpty",
                defaultValue: "New Empty Workspace Group"
            )
            if let key = newWorkspaceGroupShortcut.keyEquivalent {
                Button(newWorkspaceGroupLabel) {
                    _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
                }
                .keyboardShortcut(key, modifiers: newWorkspaceGroupShortcut.eventModifiers)
            } else {
                Button(newWorkspaceGroupLabel) {
                    _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
                }
            }
        }
    }
}

struct ExtensionSidebarBrowserStackEmptyArea: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    let rowSpacing: CGFloat
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let onNewTab: () -> Void
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2, perform: onNewTab)
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackEndDropDelegate(
                orderedRows: orderedRows,
                draggedTabId: $draggedTabId,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator,
                onMove: onMove
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(cmuxAccent.color)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastWorkspaceId = orderedRows.last?.workspaceId else { return false }
        return indicator.tabId == lastWorkspaceId
    }
}

private struct ExtensionSidebarBrowserStackEndDropDelegate: DropDelegate {
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding var draggedTabId: UUID?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
            && draggedTabId != nil
            && orderedRows.count > 1
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == nil {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId,
              let insertionPosition = insertionPositionForEndMove(draggedWorkspaceId: draggedTabId),
              let move = ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
                draggedWorkspaceId: draggedTabId,
                insertionPosition: insertionPosition
              ) else {
            return false
        }
        return onMove(move)
    }

    private func updateDropIndicator() {
        let workspaceIds = orderedRows.map(\.workspaceId)
        let nextIndicator = SidebarDropPlanner().indicator(
            draggedTabId: draggedTabId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        )
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func insertionPositionForEndMove(draggedWorkspaceId: UUID) -> Int? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        guard workspaceIds.contains(draggedWorkspaceId) else { return nil }
        guard SidebarDropPlanner().indicator(
            draggedTabId: draggedWorkspaceId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        ) != nil else {
            return nil
        }
        return workspaceIds.count
    }
}
