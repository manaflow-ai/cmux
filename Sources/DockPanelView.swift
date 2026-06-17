import AppKit
import Bonsplit
import CmuxTerminal
import CmuxTerminalEngine
import SwiftUI

/// Right-sidebar Dock. Renders the workspace's Dock `BonsplitController` tree
/// (terminals + browsers) using the same split machinery as the main content
/// area, just constrained to the sidebar width.
struct DockPanelView: View {
    let store: DockSplitStore
    let isSidebarVisible: Bool
    let mode: RightSidebarMode

    @State private var appearanceConfig = GhosttyConfig.load()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(
            DockKeyboardFocusBridge(store: store)
                .frame(width: 1, height: 1)
        )
        .accessibilityIdentifier("DockPanel")
        .onAppear { store.setActive(isVisible: isSidebarVisible, mode: mode) }
        .onDisappear { store.setVisibleInUI(false) }
        .onChange(of: isSidebarVisible) { _, visible in
            store.setActive(isVisible: visible, mode: mode)
        }
        .onChange(of: mode) { _, newMode in
            store.setActive(isVisible: isSidebarVisible, mode: newMode)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            appearanceConfig = GhosttyConfig.load()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text(store.sourceLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            Menu {
                Button {
                    store.newInFocusedPane(kind: .terminal)
                } label: {
                    Label(
                        String(localized: "dock.action.newTerminal", defaultValue: "New Terminal"),
                        systemImage: "terminal.fill"
                    )
                }
                Button {
                    store.newInFocusedPane(kind: .browser)
                } label: {
                    Label(
                        String(localized: "dock.action.newBrowser", defaultValue: "New Browser"),
                        systemImage: "globe"
                    )
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "dock.action.newSurface", defaultValue: "New Dock Pane"))
            .accessibilityLabel(String(localized: "dock.action.newSurface", defaultValue: "New Dock Pane"))

            Button {
                store.openConfiguration()
            } label: {
                Image(systemName: "doc.text")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "dock.action.openConfig", defaultValue: "Open Dock Config"))
            .accessibilityLabel(String(localized: "dock.action.openConfig", defaultValue: "Open Dock Config"))

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "dock.action.reload", defaultValue: "Reload Dock"))
            .accessibilityLabel(String(localized: "dock.action.reload", defaultValue: "Reload Dock"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 29)
    }

    @ViewBuilder
    private var content: some View {
        if let trustRequest = store.trustRequest {
            DockTrustView(request: trustRequest) {
                store.trustAndReload()
            }
        } else if let error = store.errorMessage {
            DockErrorView(message: error)
        } else {
            DockSplitContentView(
                store: store,
                appearance: PanelAppearance.fromConfig(appearanceConfig)
            )
        }
    }
}

/// Renders the Dock's Bonsplit tree, reusing `PanelContentView` so Dock
/// terminals and browsers render identically to main-area panes.
private struct DockSplitContentView: View {
    let store: DockSplitStore
    let appearance: PanelAppearance

    /// Portal z-priority for Dock-hosted terminal/browser surfaces. Kept low so
    /// Dock surfaces never overlay main-area surfaces.
    private static let portalPriority = 1

    var body: some View {
        BonsplitView(controller: store.bonsplitController) { tab, paneId in
            dockContent(tab: tab, paneId: paneId)
        } emptyPane: { paneId in
            DockEmptyPaneView(
                onNewTerminal: { _ = store.newSurface(kind: .terminal, inPane: paneId, focus: true) },
                onNewBrowser: { _ = store.newSurface(kind: .browser, inPane: paneId, focus: true) }
            )
            .onTapGesture { store.bonsplitController.focusPane(paneId) }
        }
    }

    @ViewBuilder
    private func dockContent(tab: Bonsplit.Tab, paneId: PaneID) -> some View {
        if let panel = store.panel(for: tab.id) {
            let isFocused = store.bonsplitController.focusedPaneId == paneId
            let isSelectedInPane = store.bonsplitController.selectedTab(inPane: paneId)?.id == tab.id
            let isVisibleInUI = store.isVisibleInUI && isSelectedInPane
            let isSplit = store.bonsplitController.allPaneIds.count > 1
            PanelContentView(
                panel: panel,
                workspaceId: store.workspaceId,
                paneId: paneId,
                isFocused: isFocused,
                isSelectedInPane: isSelectedInPane,
                isVisibleInUI: isVisibleInUI,
                portalPriority: Self.portalPriority,
                isSplit: isSplit,
                appearance: appearance,
                hasUnreadNotification: false,
                terminalAgentContext: "",
                paneOwnershipOverride: isSelectedInPane,
                onFocus: {
                    store.bonsplitController.focusPane(paneId)
                    store.noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
                },
                onRequestPanelFocus: {
                    store.noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
                    store.focusPanel(panel.id)
                },
                onResumeAgentHibernation: {},
                onAutoResumeAgentHibernation: {},
                onTriggerFlash: {}
            )
            .onTapGesture { store.bonsplitController.focusPane(paneId) }
        } else {
            DockEmptyPaneView(
                onNewTerminal: { _ = store.newSurface(kind: .terminal, inPane: paneId, focus: true) },
                onNewBrowser: { _ = store.newSurface(kind: .browser, inPane: paneId, focus: true) }
            )
            .onTapGesture { store.bonsplitController.focusPane(paneId) }
        }
    }
}

/// Shown in an empty Dock pane (initial empty Dock, or a freshly split pane).
/// Offers the same in-app create affordances as the tab-bar split buttons.
private struct DockEmptyPaneView: View {
    let onNewTerminal: () -> Void
    let onNewBrowser: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(String(localized: "dock.emptyPane.title", defaultValue: "Empty Dock Pane"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(action: onNewTerminal) {
                    Label(
                        String(localized: "dock.action.newTerminal", defaultValue: "New Terminal"),
                        systemImage: "terminal.fill"
                    )
                }
                Button(action: onNewBrowser) {
                    Label(
                        String(localized: "dock.action.newBrowser", defaultValue: "New Browser"),
                        systemImage: "globe"
                    )
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

private struct DockTrustView: View {
    let request: DockTrustRequest
    let onTrust: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(String(localized: "dock.trust.title", defaultValue: "Trust Project Dock?"))
                .font(.system(size: 13, weight: .semibold))
            Text(String(
                localized: "dock.trust.message",
                defaultValue: "This project wants to start commands from its Dock config."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Text(request.configPath)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Button(String(localized: "dock.trust.action", defaultValue: "Trust and Start")) {
                onTrust()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DockErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(String(localized: "dock.error.title", defaultValue: "Dock Config Error"))
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DockKeyboardFocusBridge: NSViewRepresentable {
    let store: DockSplitStore

    func makeNSView(context: Context) -> DockKeyboardFocusView {
        DockKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ nsView: DockKeyboardFocusView, context: Context) {
        nsView.focusFirstControl = { [weak store] in
            store?.focusFirstControl() == true
        }
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class DockKeyboardFocusView: NSView {
    var focusFirstControl: (() -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerWithKeyboardFocusCoordinatorIfNeeded() }

    func registerWithKeyboardFocusCoordinatorIfNeeded() { if let window { AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerDockHost(self) } }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let surfaceId = ghosttyView.terminalSurface?.id else {
            return false
        }
        return GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: surfaceId)
    }

    func focusFirstItemFromCoordinator() { _ = focusFirstControl?() }

    func focusHostFromCoordinator() -> Bool {
        focusFirstControl?() == true || window?.makeFirstResponder(self) == true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { handleModeShortcut(event) || super.performKeyEquivalent(with: event) }

    override func keyDown(with event: NSEvent) { if !handleModeShortcut(event) { super.keyDown(with: event) } }

    private func handleModeShortcut(_ event: NSEvent) -> Bool {
        guard let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) else { return false }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(mode: mode, focusFirstItem: true, preferredWindow: window)
        return true
    }
}
