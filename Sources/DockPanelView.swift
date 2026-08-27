import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxNotifications
import CmuxTerminal
import SwiftUI

/// Right-sidebar Dock. Renders the window's own Dock `BonsplitController` tree
/// (terminals + browsers) using the same split machinery as the main content
/// area, just constrained to the sidebar width. Every window mounts its own
/// store, so multiple windows can each show a live Dock simultaneously.
struct DockPanelView: View {
    let store: DockSplitStore
    let isSidebarVisible: Bool
    let mode: RightSidebarMode
    let rootDirectory: String?
    let windowAppearance: WindowAppearanceSnapshot
    /// True when the right sidebar (this Dock) owns keyboard focus. The Dock
    /// dims its focus ring when false so Dock and main-pane focus are mutually
    /// exclusive (the main pane dims its ring when this is true).
    var rightSidebarOwnsInputFocus: Bool = false

    @State private var appearanceConfig = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "dock.initial")
    @State private var appearanceRevision: UInt = 0
    @State private var unreadProjection: DockUnreadPanelProjection
    @State private var visibilityHostId = UUID()

    @MainActor
    init(
        store: DockSplitStore,
        isSidebarVisible: Bool,
        mode: RightSidebarMode,
        rootDirectory: String?,
        windowAppearance: WindowAppearanceSnapshot,
        rightSidebarOwnsInputFocus: Bool = false,
        unreadSource: SidebarUnreadModel
    ) {
        self.store = store
        self.isSidebarVisible = isSidebarVisible
        self.mode = mode
        self.rootDirectory = rootDirectory
        self.windowAppearance = windowAppearance
        self.rightSidebarOwnsInputFocus = rightSidebarOwnsInputFocus
        _unreadProjection = State(initialValue: DockUnreadPanelProjection(
            source: unreadSource,
            workspaceID: store.workspaceId,
            panelIDs: Set(store.panels.keys),
            isActive: isSidebarVisible && mode == .dock,
            agentAttentionSource: store.agentNeedsInputAttention
        ))
    }

    private var appearance: PanelAppearance {
        PanelAppearance.fromConfig(appearanceConfig)
    }

    private var resolvedChromeBackgroundIdentity: String {
        windowAppearance.resolvedChromeBackgroundColor.hexString(includeAlpha: true)
    }

    var body: some View {
        content
        // Bonsplit and hosted panel subtrees may create their own AppKit
        // hosting boundary. Re-inject the snapshot authority at the Dock root
        // so none of that chrome falls back to macOS's ambient appearance.
        .environment(\.colorScheme, windowAppearance.resolvedColorScheme)
        // The window root (or the right-sidebar material) owns the backdrop.
        // Bonsplit terminal surfaces are intentionally clear, so a concrete
        // composited chrome color here would cut them off from that owner.
        .background(
            WindowBackdropLayer(role: .bonsplitChrome, snapshot: windowAppearance)
        )
        .background(
            DockKeyboardFocusBridge(store: store)
                .frame(width: 1, height: 1)
        )
        .background(
            DockUnreadProjectionContextBridge(
                projection: unreadProjection,
                panelIDs: Set(store.panels.keys),
                isActive: isSidebarVisible && mode == .dock
            )
            .frame(width: 0, height: 0)
        )
        .accessibilityIdentifier("DockPanel")
        .onAppear {
            refreshAppearance(reason: "onAppear")
            store.setRootDirectory(rootDirectory)
            store.setActive(isVisible: isSidebarVisible, mode: mode, visibilityHostId: visibilityHostId)
        }
        .onDisappear { store.setVisibleInUI(false, hostId: visibilityHostId) }
        .onChange(of: isSidebarVisible) { _, visible in
            store.setActive(isVisible: visible, mode: mode, visibilityHostId: visibilityHostId)
        }
        .onChange(of: mode) { _, newMode in
            store.setActive(isVisible: isSidebarVisible, mode: newMode, visibilityHostId: visibilityHostId)
        }
        .onChange(of: rootDirectory) { _, _ in
            store.setRootDirectory(rootDirectory)
            store.setActive(isVisible: isSidebarVisible, mode: mode, visibilityHostId: visibilityHostId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            refreshAppearance(reason: "ghosttyConfigDidReload")
        }
        .onReceive(NotificationCenter.default.publisher(for: PaneChromeSettings.didChangeNotification)) { _ in
            refreshAppearance(reason: "paneChromeSettingsDidChange")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
            refreshAppearance(reason: "ghosttyDefaultBackgroundDidChange")
        }
        .onChange(of: windowAppearance.resolvedColorScheme) { _, _ in
            // The Dock's Bonsplit controller is an AppKit subtree and does not
            // inherit SwiftUI's environment automatically. Re-apply its
            // concrete chrome whenever the shared theme authority changes.
            refreshAppearance(reason: "resolvedColorSchemeChanged")
        }
        .onChange(of: resolvedChromeBackgroundIdentity) { _, _ in
            refreshAppearance(reason: "resolvedChromeBackgroundChanged")
        }
    }

    private func refreshAppearance(reason: String) {
        let next = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "dock.\(reason)")
        appearanceConfig = next
        appearanceRevision &+= 1
        store.applyGhosttyChrome(from: next, windowAppearance: windowAppearance)
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
                appearance: appearance,
                appearanceRevision: appearanceRevision,
                windowAppearance: windowAppearance,
                rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
                unreadPanelIDs: unreadProjection.unreadPanelIDs
            )
        }
    }
}

/// Shown in an empty Dock pane (initial empty Dock, or a freshly split pane).
/// Offers the same in-app create affordances as the tab-bar split buttons.
struct DockEmptyPaneView: View {
    let onNewTerminal: () -> Void
    let onNewBrowser: () -> Void
    let browserAvailable: Bool

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
                if browserAvailable {
                    Button(action: onNewBrowser) {
                        Label(
                            String(localized: "dock.action.newBrowser", defaultValue: "New Browser"),
                            systemImage: "globe"
                        )
                    }
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
        nsView.ownsDockBrowserFocus = { [weak store] responder, window in
            store?.browserPanel(owning: responder, in: window) != nil
        }
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class DockKeyboardFocusView: NSView {
    var focusFirstControl: (() -> Bool)?
    var ownsDockBrowserFocus: ((NSResponder, NSWindow) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerWithKeyboardFocusCoordinatorIfNeeded() }

    func registerWithKeyboardFocusCoordinatorIfNeeded() { if let window { AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerDockHost(self) } }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        if let window, ownsDockBrowserFocus?(responder, window) == true { return true }
        guard let ghosttyView = responder.cmuxStrictOwningGhosttyView(),
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
