#if DEBUG
import AppKit
import SwiftUI

/// Debug-only Cloud tree style picker (Debug → Debug Windows → Cloud Tree Style
/// Gallery…, or the `debug.cloudtree.gallery` socket verb): every
/// ``CloudTreeStyle`` preset rendered side by side over the live surface
/// catalog, each with a "Use" button that makes it the sidebar's style on the
/// spot. Strings are English-only by design: the file is `#if DEBUG`, matching
/// the other debug windows.
final class CloudTreeStyleGalleryWindowController: ReleasingWindowController {
    static let shared = CloudTreeStyleGalleryWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cloud Tree Style Gallery"
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloudTreeStyleGallery")
        window.minSize = NSSize(width: 900, height: 420)
        // Float above the workspace windows so frame-capture screenshots reliably
        // target this window.
        window.level = .floating
        window.center()
        window.contentView = NSHostingView(rootView: CloudTreeStyleGalleryRootView())
        return window
    }

    func show() {
        showManagedWindow(activateApplication: true, orderFrontRegardless: true)
        window?.makeKey()
    }
}

private struct CloudTreeStyleGalleryRootView: View {
    @State private var snapshot: SurfaceCatalogSnapshot = SurfaceCatalog.shared.snapshot
    @State private var localWorkspaces: [CloudTreeLocalWorkspace] = currentLocalWorkspaces()
    @AppStorage(CloudTreeStyleStore.defaultsKey) private var selectedStyleID: String = CloudTreeStyle.defaultStyle.id

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(CloudTreeStyle.presets.enumerated()), id: \.element.id) { index, style in
                if index > 0 { Divider() }
                CloudTreeStyleGalleryColumn(
                    style: style,
                    isSelected: style.id == selectedStyleID,
                    snapshot: snapshot,
                    localWorkspaces: localWorkspaces,
                    select: { selectedStyleID = style.id }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SurfaceCatalog.didChangeNotification)) { _ in
            snapshot = SurfaceCatalog.shared.snapshot
            localWorkspaces = currentLocalWorkspaces()
        }
        .frame(minWidth: 900, minHeight: 420)
    }
}

@MainActor
private func currentLocalWorkspaces() -> [CloudTreeLocalWorkspace] {
    guard let tabManager = AppDelegate.shared?.tabManager else { return [] }
    let selected = tabManager.selectedTabId
    return tabManager.tabs.map { CloudTreeLocalWorkspace(id: $0.id, title: $0.title, isSelected: $0.id == selected) }
}

private struct CloudTreeStyleGalleryColumn: View {
    let style: CloudTreeStyle
    let isSelected: Bool
    let snapshot: SurfaceCatalogSnapshot
    let localWorkspaces: [CloudTreeLocalWorkspace]
    let select: () -> Void

    @State private var expansionStore = CloudTreeExpansionStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(style.name)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(Int(style.rowHeight))pt")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if isSelected {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Use", action: select)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            CloudTreeOutlineView(
                machines: [],
                snapshot: snapshot,
                localWorkspaces: localWorkspaces,
                machineActions: MachineRowActions.bound(onDidMutate: {}),
                nodeActions: CloudTreeNodeActions.bound(
                    catalog: { SurfaceCatalog.shared },
                    selectedWorkspaceID: { AppDelegate.shared?.tabManager?.selectedTabId },
                    selectLocalWorkspace: { workspaceID in
                        AppDelegate.shared?.tabManager?.selectedTabId = workspaceID
                    },
                    onWillMutate: { _ in },
                    onDidMutate: {},
                    onFailure: { _ in },
                    refresh: { Task { await CmuxTuiSurfaceProviderRegistry.shared.refresh(force: true) } }
                ),
                expansionStore: expansionStore,
                style: style
            )
        }
    }
}

/// Deterministic production-row preview for spacing and pending-state checks.
/// Actions are inert: opening this window never provisions or deletes a machine.
final class CloudTreeLayoutPreviewWindowController: ReleasingWindowController {
    static let shared = CloudTreeLayoutPreviewWindowController()

    override func makeWindow() -> NSWindow {
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions,
            nodeActions: Self.nodeActions,
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-row-layout-preview")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let request = MachineCreateRequest(mode: .newMachine, kind: .desktop, name: nil, arguments: [])
        let pending = MachineCreateOperation(id: UUID(), request: request, startedAt: Date())
        var failed = MachineCreateOperation(id: UUID(), request: request, startedAt: Date())
        failed.phase = .failed(output: "Preview failure")
        let machine = MachineSnapshot(
            id: "preview-machine",
            provider: "",
            image: "",
            isDesktop: false,
            activity: .ready,
            createdAt: nil,
            label: "wise-ruby-crane"
        )
        coordinator.apply(nodes: [
            CloudTreeNode(id: "preview-pending", kind: .pendingMachine(pending)),
            CloudTreeNode(id: "preview-failed", kind: .pendingMachine(failed)),
            CloudTreeNode(id: "preview-ready", kind: .machine(machine, nil), children: [
                CloudTreeNode(id: "preview-workspaces", kind: .workspacesGroup(.cloud(machine.id)))
            ])
        ])
        coordinator.outlineView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 345, height: 160),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cloud Row Layout Preview"
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloudRowLayoutPreview")
        window.minSize = NSSize(width: 240, height: 140)
        window.contentView = container
        return window
    }

    func show() {
        showManagedWindow()
    }

    private static let machineActions = MachineRowActions(
        openShell: { _ in },
        openDesktop: { _ in },
        runCommand: { _, _ in },
        confirmDelete: { _ in },
        promptRename: { _, _ in },
        resizeDisk: { _, _ in },
        promptUpgrade: {}
    )

    private static let nodeActions = CloudTreeNodeActions(
        project: { _, _, _ in },
        projectRemoteView: { _, _, _, _ in },
        projectInLocalWorkspace: { _, _ in },
        projectRemoteViewInLocalWorkspace: { _, _, _ in },
        newTerminal: { _, _ in },
        openGroup: { _, _, _, _ in },
        openGroupAsWorkspace: { _, _, _ in },
        newWorkspace: { _ in },
        closeTerminal: { _ in },
        closeWorkspace: { _, _ in },
        renameWorkspace: { _, _ in },
        renameTerminal: { _, _ in },
        selectLocalWorkspace: { _ in },
        copyToPasteboard: { _ in },
        refresh: {}
    )

}
#endif
