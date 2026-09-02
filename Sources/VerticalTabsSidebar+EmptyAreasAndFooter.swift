import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
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

struct SidebarAccountMenuButton: View {
    @EnvironmentObject private var tabManager: TabManager
    private var accountFlow: HostAccountFlow? { AppDelegate.shared?.auth?.accountFlow }
    private let title = String(localized: "settings.section.account", defaultValue: "Account")
    private let signInTitle = String(localized: "settings.account.signIn", defaultValue: "Sign In…")
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    @State private var isPopoverPresented = false
#if DEBUG
    @AppStorage(SidebarFooterProfileIconDebugSettings.sizeKey)
    private var debugIconSize = SidebarFooterProfileIconDebugSettings.defaultSize
    @AppStorage(SidebarFooterProfileDisplayDebugSettings.displayKey)
    private var debugProfileDisplay = SidebarFooterProfileDisplayDebugSettings.defaultDisplay.rawValue
#endif

    private var profileIconSize: CGFloat {
#if DEBUG
        CGFloat(debugIconSize)
#else
        SidebarFooterButtonMetrics.profileIconSize
#endif
    }

    private var prefersProfileIcon: Bool {
#if DEBUG
        SidebarFooterProfileDisplayDebugChoice(rawValue: debugProfileDisplay) == .icon
#else
        false
#endif
    }

    private func presentation(
        isSignedIn: Bool,
        hasProfilePicture: Bool
    ) -> SidebarAccountButtonPresentation {
        let presentation = SidebarAccountButtonPresentation.resolve(
            isSignedIn: isSignedIn,
            prefersProfileIcon: prefersProfileIcon,
            hasProfilePicture: hasProfilePicture
        )
#if DEBUG
        if !presentation.showsProfilePicture {
            return SidebarAccountButtonPresentation(
                visual: presentation.visual,
                size: profileIconSize
            )
        }
#endif
        return presentation
    }

    var body: some View {
        let identity = accountFlow?.currentIdentity
        let isSignedIn = identity != nil
        let buttonTitle = isSignedIn ? title : signInTitle
        let presentation = presentation(
            isSignedIn: isSignedIn,
            hasProfilePicture: identity?.avatarURL != nil
        )
        Button {
            if isSignedIn {
                isPopoverPresented.toggle()
            } else {
                _ = AppDelegate.shared?.performAccountSignInWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "sidebar.account"
                )
            }
        } label: {
            SidebarAccountAvatar(
                avatarURL: identity?.avatarURL,
                displayName: identity?.displayName ?? "",
                email: identity?.email ?? "",
                isSignedIn: presentation.showsProfilePicture,
                size: presentation.size
            )
            .frame(width: buttonSize, height: buttonSize)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .disabled(accountFlow?.isWorkingOnAuth == true)
        .frame(width: buttonSize, height: buttonSize)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            SidebarAccountPopover(
                accountFlow: accountFlow,
                dismiss: { isPopoverPresented = false }
            )
        })
        .safeHelp(buttonTitle)
        .accessibilityLabel(buttonTitle)
        .accessibilityIdentifier("SidebarAccountMenuButton")
    }
}

private struct SidebarAccountPopover: View {
    let accountFlow: HostAccountFlow?
    let dismiss: () -> Void
    @Environment(\.chromePalette) private var chromePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let identity = accountFlow?.currentIdentity {
                HStack(spacing: 10) {
                    SidebarAccountAvatar(
                        avatarURL: identity.avatarURL,
                        displayName: identity.displayName,
                        email: identity.email,
                        isSignedIn: true,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.displayName.isEmpty ? identity.email : identity.displayName)
                            .cmuxFont(size: 13, weight: .semibold)
                            .lineLimit(1)
                        if !identity.email.isEmpty && identity.email != identity.displayName {
                            Text(identity.email)
                                .cmuxFont(size: 11)
                                .foregroundStyle(chromePalette.textSecondary.swiftUIColor)
                                .lineLimit(1)
                        }
                    }
                }
                Divider()
            } else {
                Text(String(localized: "settings.account.signedOut.title", defaultValue: "Not signed in"))
                    .cmuxFont(size: 13, weight: .semibold)
                Button {
                    dismiss()
                    accountFlow?.startSignIn()
                } label: {
                    Label(
                        String(localized: "settings.account.signIn", defaultValue: "Sign In…"),
                        systemImage: "person.crop.circle.badge.plus"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("SidebarAccountSignInButton")
            }
            if accountFlow?.isProUpgradeAvailable == true {
                if accountFlow?.currentIdentity == nil {
                    Divider()
                }
                Button {
                    dismiss()
                    accountFlow?.openProUpgrade()
                } label: {
                    Label(
                        String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                        systemImage: "sparkles"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("SidebarAccountUpgradeButton")
            }
            if accountFlow?.currentIdentity != nil {
                Button {
                    dismiss()
                    Task { await accountFlow?.signOut() }
                } label: {
                    Label(
                        String(localized: "settings.account.signOut", defaultValue: "Sign Out"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("SidebarAccountSignOutButton")
            }
        }
        .buttonStyle(.plain)
        .disabled(accountFlow?.isWorkingOnAuth == true)
        .padding(12)
        .frame(width: 220, alignment: .leading)
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
    @Environment(\.chromePalette) private var chromePalette
    private let title = String(localized: "command.mobileConnect.title", defaultValue: "Open Tailscale Pairing")
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
                CmuxSystemSymbolImage(systemName: "iphone", pointSize: iconSize, weight: .medium)
                    .foregroundStyle(chromePalette.textSecondary.swiftUIColor)
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
            .accessibilityLabel(title)
            .accessibilityIdentifier("SidebarMobileConnectButton")
        }
    }
}

private struct SidebarFooterIconButtonStyleBody: View {
    @Environment(\.chromePalette) private var chromePalette
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
                    .fill(chromePalette.surfaceHover.swiftUIColor.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
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
    @Environment(\.chromePalette) private var chromePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, modifierKeyMonitor: modifierKeyMonitor, onSendFeedback: onSendFeedback)
            if showSidebarDevBuildBanner {
                Text(String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD"))
                    .cmuxFont(size: 11, weight: .semibold)
                    .foregroundColor(chromePalette.agentError.swiftUIColor)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }
}
#endif

struct SidebarEmptyArea: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.chromePalette) private var chromePalette
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
                        .fill(chromePalette.cmuxAccentColor)
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
                // When the active workspace is a remote-tmux mirror, route through
                // performNewWorkspaceAction so a new workspace becomes a new tmux
                // session instead of a local (orphan) workspace. Gate on the
                // SELECTED tab, not `tabs.contains`: a dedicated remote window can
                // be polluted with a dragged-in local workspace (move targets don't
                // exclude dedicated windows), and `contains` would then misroute a
                // local empty-area double-tap into spawning an unwanted tmux session.
                if tabManager.selectedTab?.isRemoteTmuxMirror == true {
                    _ = AppDelegate.shared?.performNewWorkspaceAction(
                        tabManager: tabManager,
                        debugSource: "sidebar.emptyArea.remoteTmux"
                    )
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
    @Environment(\.chromePalette) private var chromePalette
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
                        .fill(chromePalette.cmuxAccentColor)
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
