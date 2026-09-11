import AppKit
import CmuxAppKitSupportUI
import SwiftUI

extension Notification.Name {
    /// Debug socket → sidebar footer. `object` is the target `NSWindow` (nil
    /// means the key window); `userInfo["show"]` is a Bool to force a state,
    /// absent to toggle.
    static let sidebarCloudWorkspacesPopoverRequested = Notification.Name("cmux.sidebarCloudWorkspacesPopoverRequested")
}

/// Whether any footer Cloud Workspaces popover is open, so the debug socket
/// verb can report the state it just requested.
@MainActor
enum SidebarCloudWorkspacesPopoverPresence {
    static var isPresented = false
}

/// The bottom-left Cloud button: opens a workspace switcher over this Mac's
/// sidebar workspaces and every Cloud machine's workspaces, in one tree.
struct SidebarCloudWorkspacesButton: View {
    @EnvironmentObject private var tabManager: TabManager
    private let title = String(localized: "sidebar.cloudWorkspaces.button", defaultValue: "Cloud Workspaces")
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    @State private var isPopoverPresented = false
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            setPresented(!isPopoverPresented)
        } label: {
            SidebarFooterCircularIcon(systemName: "cloud", style: .standard)
                .frame(width: buttonSize, height: buttonSize)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize)
        .background(TitlebarControlAnchorView { anchorView = $0 })
        .background(alignment: .bottomLeading) {
            // AppKit centers a popover on its anchor view, so a 320pt popover on a
            // 22pt corner button would spill past the window. The anchor spans the
            // popover's width from the button's leading edge; it is click-through.
            Color.clear
                .frame(width: SidebarCloudWorkspacesPopover.size.width, height: buttonSize)
                .background(ArrowlessPopoverAnchor(
                    isPresented: $isPopoverPresented,
                    preferredEdge: .maxY,
                    detachedGap: 4
                ) {
                    SidebarCloudWorkspacesPopover(tabManager: tabManager, dismiss: { setPresented(false) })
                })
                .allowsHitTesting(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidebarCloudWorkspacesPopoverRequested)) { notification in
            // One footer per main window: only the addressed (or key) window answers.
            guard ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: anchorView?.window,
                requestedWindow: notification.object as? NSWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            setPresented((notification.userInfo?["show"] as? Bool) ?? !isPopoverPresented)
        }
        .onChange(of: isPopoverPresented) { _, presented in
            // The popover's own close (click-away, Escape) lands here.
            SidebarCloudWorkspacesPopoverPresence.isPresented = presented
        }
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("SidebarCloudWorkspacesButton")
    }

    private func setPresented(_ presented: Bool) {
        isPopoverPresented = presented
        SidebarCloudWorkspacesPopoverPresence.isPresented = presented
    }
}

/// The switcher body: the Cloud tree with This Mac first (every sidebar
/// workspace, terminal or not), then each machine. Clicking a local workspace
/// selects it and closes the popover; Cloud rows use the Machines panel's
/// shared action path, so opening a Cloud workspace behaves exactly as it does
/// in the right sidebar.
struct SidebarCloudWorkspacesPopover: View {
    static let size = CGSize(width: 320, height: 440)
    @ObservedObject var tabManager: TabManager
    let dismiss: () -> Void
    @StateObject private var viewModel = MachinesPanelViewModel()
    @State private var expansionStore = CloudTreeExpansionStore()
    @AppStorage(CloudTreeStyleStore.defaultsKey) private var cloudTreeStyleID: String = CloudTreeStyle.defaultStyle.id

    private var accountFlow: HostAccountFlow? { AppDelegate.shared?.auth?.accountFlow }
    private var isSignedIn: Bool { accountFlow?.isAuthenticated == true }

    private var localWorkspaces: [CloudTreeLocalWorkspace] {
        let selected = tabManager.selectedTabId
        return tabManager.tabs.map { CloudTreeLocalWorkspace(id: $0.id, title: $0.title, isSelected: $0.id == selected) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tree
            if !isSignedIn {
                footerNote(
                    String(localized: "sidebar.cloudWorkspaces.signedOut", defaultValue: "Sign in to see your Cloud workspaces."),
                    buttonTitle: String(localized: "settings.account.signIn", defaultValue: "Sign In…")
                ) {
                    dismiss()
                    accountFlow?.startSignIn()
                }
            } else if viewModel.hasLoadedOnce, viewModel.machines.isEmpty, viewModel.pendingCreates.isEmpty {
                footerNote(
                    String(localized: "machines.empty.title", defaultValue: "No machines yet"),
                    buttonTitle: String(localized: "machines.empty.create", defaultValue: "New Machine"),
                    action: requestNewMachine
                )
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear {
            viewModel.readCatalog()
            if isSignedIn { viewModel.startPolling() }
        }
        .onDisappear { viewModel.stopPolling() }
        .accessibilityIdentifier("SidebarCloudWorkspacesPopover")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(String(localized: "sidebar.cloudWorkspaces.button", defaultValue: "Cloud Workspaces"))
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let error = viewModel.lastErrorDescription, isSignedIn {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help(error)
            }
            if isSignedIn {
                MachinesChromeIconButton(
                    symbolName: "arrow.clockwise",
                    accessibilityLabel: String(localized: "machines.refresh", defaultValue: "Refresh Machines"),
                    isBusy: viewModel.isLoading
                ) {
                    viewModel.refresh(tree: true)
                }
                MachinesChromeIconButton(
                    symbolName: "plus",
                    accessibilityLabel: String(localized: "machines.new", defaultValue: "New Machine"),
                    isBusy: false,
                    action: requestNewMachine
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var tree: some View {
        var machineActions = MachineRowActions.bound(
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
            onDidMutate: { [weak viewModel] in viewModel?.endOperation() }
        )
        machineActions.create = MachineCreateRowActions.bound(coordinator: viewModel.createCoordinator)
        let nodeActions = CloudTreeNodeActions.bound(
            catalog: { SurfaceCatalog.shared },
            selectedWorkspaceID: { [tabManager] in tabManager.selectedTabId },
            selectLocalWorkspace: { [tabManager] workspaceID in
                tabManager.selectedTabId = workspaceID
                dismiss()
            },
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
            onDidMutate: { [weak viewModel] in viewModel?.endOperation() },
            onFailure: { [weak viewModel] description in viewModel?.noteTreeFailure(description) },
            refresh: { [weak viewModel] in viewModel?.refresh(tree: true) }
        )
        return CloudTreeOutlineView(
            machines: isSignedIn ? viewModel.machines : [],
            pendingCreates: viewModel.pendingCreates,
            snapshot: viewModel.catalog,
            localWorkspaces: localWorkspaces,
            unreadTerminalIDs: viewModel.unreadTerminalIDs,
            includesLocalMachine: true,
            includesEmptyLocalWorkspaces: true,
            machineActions: machineActions,
            nodeActions: nodeActions,
            expansionStore: expansionStore,
            style: CloudTreeStyle.preset(id: cloudTreeStyleID) ?? .defaultStyle,
            onDragStateChange: { [weak viewModel] dragging in viewModel?.setTreeDragging(dragging) }
        )
        .accessibilityIdentifier("SidebarCloudWorkspacesTree")
    }

    private func footerNote(_ text: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(text)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(action: action) {
                    Text(buttonTitle).cmuxFont(size: 11)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func requestNewMachine() {
        NewMachineSheetPresenter.shared.presentNewMachine(
            plan: viewModel.plan,
            memoryOptionsMb: viewModel.memoryOptionsMb,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            coordinator: viewModel.createCoordinator
        )
    }
}
