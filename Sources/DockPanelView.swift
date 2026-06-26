import AppKit
import CmuxFoundation
import CmuxSidebar
import CmuxTerminal
import Bonsplit
import Observation
import SwiftUI

struct DockTrustRequest: Identifiable {
    var id: String { descriptor.fingerprint }
    let descriptor: CmuxActionTrustDescriptor
    let configPath: String
}

@MainActor
@Observable
final class DockControlRuntime: Identifiable {
    let id: String
    let definition: DockControlDefinition
    let baseDirectory: String
    let workspaceId: UUID
    let paneId: PaneID
    private(set) var panel: TerminalPanel

    init(definition: DockControlDefinition, baseDirectory: String, workspaceId: UUID) {
        self.id = definition.id
        self.definition = definition
        self.baseDirectory = baseDirectory
        self.workspaceId = workspaceId
        self.paneId = PaneID(id: UUID())
        self.panel = Self.makePanel(definition: definition, baseDirectory: baseDirectory, workspaceId: workspaceId)
    }

    fileprivate var snapshot: DockControlSnapshot { .init(id: id, title: definition.title, command: definition.command, requestedHeight: definition.height) }

    fileprivate var terminalAttachment: DockTerminalAttachment { .init(paneId: paneId, panelId: panel.id, terminalSurface: panel.surface, searchState: panel.searchState, reattachToken: panel.viewReattachToken) }

    func focus() {
        panel.hostedView.ensureFocus(
            for: panel.surface.tabId,
            surfaceId: panel.id,
            respectForeignFirstResponder: false
        )
    }

    func restart() {
        let oldPanel = panel
        panel = Self.makePanel(definition: definition, baseDirectory: baseDirectory, workspaceId: workspaceId)
        oldPanel.close()
    }

    func close() {
        panel.close()
    }

    func setVisibleInUI(_ visible: Bool) {
        if visible {
            panel.hostedView.setVisibleInUI(true)
            TerminalWindowPortalRegistry.updateEntryVisibility(
                for: panel.hostedView,
                visibleInUI: true
            )
        } else {
            panel.unfocus()
            panel.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(panel.hostedView)
        }
    }

    private static func makePanel(
        definition: DockControlDefinition,
        baseDirectory: String,
        workspaceId: UUID
    ) -> TerminalPanel {
        var environment = definition.env
        environment["CMUX_DOCK_CONTROL_ID"] = definition.id
        environment["CMUX_DOCK_CONTROL_TITLE"] = definition.title

        let workingDirectory = DockStartupScript.resolvedWorkingDirectory(definition.cwd, baseDirectory: baseDirectory)
        return TerminalPanel(
            workspaceId: workspaceId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            workingDirectory: workingDirectory,
            initialCommand: DockStartupScript(
                command: definition.command,
                workingDirectory: workingDirectory
            ).materializedPath,
            initialEnvironmentOverrides: environment,
            focusPlacement: .rightSidebarDock
        )
    }

}

fileprivate struct DockTerminalAttachment { let paneId: PaneID; let panelId: UUID; let terminalSurface: TerminalSurface; let searchState: TerminalSurface.SearchState?; let reattachToken: UInt64 }

@MainActor
@Observable
final class DockControlsStore {
    private(set) var controls: [DockControlRuntime] = []
    private(set) var sourceLabel = ""
    private(set) var errorMessage: String?
    private(set) var trustRequest: DockTrustRequest?

    private var lastRootDirectory: String?
    private var lastWorkspaceId: UUID?
    private var activeConfigURL: URL?
    private var hasLoadedConfiguration = false
    private var controlsVisibleInUI = false

    // `DockConfigResolver` lives in CmuxSidebar, which has no localization
    // bundle, so the resolved error and source-label strings are localized here
    // (app bundle) and injected. Resolving once at construction is faithful: the
    // locale is fixed for the app's lifetime.
    private let configResolver = DockConfigResolver(
        decodingStrings: DockControlDecodingStrings(
            blankControlID: String(localized: "dock.error.blankControlID", defaultValue: "Dock control id must not be blank."),
            blankControlCommand: String(localized: "dock.error.blankControlCommand", defaultValue: "Dock control command must not be blank.")
        ),
        duplicateControlMessage: String(localized: "dock.error.duplicateControl", defaultValue: "Dock control ids must be unique."),
        sourceTitle: String(localized: "dock.source.title", defaultValue: "Dock"),
        sourceProject: String(localized: "dock.source.project", defaultValue: "Project Dock"),
        sourceGlobal: String(localized: "dock.source.global", defaultValue: "Global Dock")
    )

    fileprivate var controlSnapshots: [DockControlSnapshot] {
        controls.map(\.snapshot)
    }

    fileprivate func terminalAttachment(for controlID: String) -> DockTerminalAttachment? { controls.first { $0.id == controlID }?.terminalAttachment }

    func synchronizeSidebarLifecycle(
        isRightSidebarVisible: Bool,
        mode: RightSidebarMode,
        rootDirectory: String?,
        workspaceId: UUID?
    ) {
        guard isRightSidebarVisible, mode == .dock else {
            deactivate()
            return
        }
        activate(rootDirectory: rootDirectory, workspaceId: workspaceId)
    }

    func activate(rootDirectory: String?, workspaceId: UUID?) {
        controlsVisibleInUI = true
        if hasLoadedConfiguration, lastRootDirectory == rootDirectory {
            if workspaceId == nil || lastWorkspaceId == workspaceId {
                setControlsVisibleInUI(true)
                return
            }
        }
        reload(rootDirectory: rootDirectory, workspaceId: workspaceId)
    }

    func deactivate() {
        controlsVisibleInUI = false
        setControlsVisibleInUI(false)
    }

    func reload(rootDirectory: String?, workspaceId: UUID?) {
        lastRootDirectory = rootDirectory
        lastWorkspaceId = workspaceId
        hasLoadedConfiguration = true
        errorMessage = nil
        trustRequest = nil
        activeConfigURL = nil

        guard let workspaceId else {
            replaceControls(with: [])
            sourceLabel = String(localized: "dock.source.title", defaultValue: "Dock")
            return
        }

        do {
            let resolution = try configResolver.resolve(rootDirectory: rootDirectory)
            activeConfigURL = resolution.sourceURL
            if let request = trustRequestIfNeeded(for: resolution) {
                replaceControls(with: [])
                sourceLabel = String(
                    localized: "dock.source.project",
                    defaultValue: "Project Dock"
                )
                trustRequest = request
                return
            }
            let resolvedControls = resolution.controls.map {
                DockControlRuntime(definition: $0, baseDirectory: resolution.baseDirectory, workspaceId: workspaceId)
            }
            replaceControls(with: resolvedControls)
            sourceLabel = configResolver.sourceLabel(for: resolution)
        } catch {
            replaceControls(with: [])
            sourceLabel = String(localized: "dock.source.error", defaultValue: "Dock")
            errorMessage = error.localizedDescription
        }
    }

    func trustAndReload() {
        if let trustRequest {
            CmuxActionTrust.shared.trust(trustRequest.descriptor)
        }
        reload(rootDirectory: lastRootDirectory, workspaceId: lastWorkspaceId)
    }

    func focusFirstControl() -> Bool {
        guard let first = controls.first else { return false }
        first.focus()
        return true
    }

    func openConfiguration() {
        do {
            let target: URL
            if let activeConfigURL {
                target = activeConfigURL
            } else {
                target = try configResolver.preferredEditableConfigURL(rootDirectory: lastRootDirectory)
            }
            if !FileManager.default.fileExists(atPath: target.path) {
                try configResolver.writeTemplate(to: target)
            }
            NSWorkspace.shared.open(target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func focusControl(id: String) {
        controls.first { $0.id == id }?.focus()
    }

    func restartControl(id: String) {
        guard let index = controls.firstIndex(where: { $0.id == id }) else { return }
        let oldControl = controls[index]
        let newControl = DockControlRuntime(
            definition: oldControl.definition,
            baseDirectory: oldControl.baseDirectory,
            workspaceId: oldControl.workspaceId
        )
        controls[index] = newControl
        newControl.setVisibleInUI(controlsVisibleInUI)
        oldControl.close()
    }

    func noteKeyboardFocusIntent(id: String, window: NSWindow?) {
        guard controls.contains(where: { $0.id == id }) else { return }
        AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
    }

    func triggerFlash(id: String) {
        controls.first { $0.id == id }?.panel.triggerFlash(reason: .debug)
    }

    private func replaceControls(with newControls: [DockControlRuntime]) {
        let oldControls = controls
        controls = newControls
        newControls.forEach { $0.setVisibleInUI(controlsVisibleInUI) }
        oldControls.forEach { $0.close() }
    }

    private func setControlsVisibleInUI(_ visible: Bool) {
        controls.forEach { $0.setVisibleInUI(visible) }
    }

    private func trustRequestIfNeeded(for resolution: DockConfigResolution) -> DockTrustRequest? {
        guard resolution.isProjectSource,
              let sourceURL = resolution.sourceURL else {
            return nil
        }
        let descriptor = Self.trustDescriptor(for: resolution)
        guard !CmuxActionTrust.shared.isTrusted(descriptor) else { return nil }
        return DockTrustRequest(
            descriptor: descriptor,
            configPath: sourceURL.path
        )
    }

    private static func trustDescriptor(for resolution: DockConfigResolution) -> CmuxActionTrustDescriptor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(DockConfigFile(controls: resolution.controls))) ?? Data()
        let commandFingerprint = String(data: data, encoding: .utf8) ?? ""
        return CmuxActionTrustDescriptor(
            actionID: "cmux.dock",
            kind: "dockControls",
            command: commandFingerprint,
            target: "rightSidebarDock",
            workspaceCommand: nil,
            configPath: resolution.sourceURL.map { $0.path.canonicalizedFilePath },
            projectRoot: resolution.baseDirectory.canonicalizedFilePath,
            iconFingerprint: nil
        )
    }
}

struct DockPanelView: View {
    let rootDirectory: String?
    let workspaceId: UUID?
    let store: DockControlsStore

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
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text(store.sourceLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
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
                store.reload(rootDirectory: rootDirectory, workspaceId: workspaceId)
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
        } else if store.controls.isEmpty {
            DockEmptyView()
        } else {
            DockControlsLayoutView(
                snapshots: store.controlSnapshots,
                terminalAttachment: { id in store.terminalAttachment(for: id) },
                onFocus: { id in store.focusControl(id: id) },
                onRestart: { id in store.restartControl(id: id) },
                onKeyboardFocusIntent: { id, window in store.noteKeyboardFocusIntent(id: id, window: window) },
                onTriggerFlash: { id in store.triggerFlash(id: id) }
            )
        }
    }
}

private struct DockControlsLayoutView: View {
    let snapshots: [DockControlSnapshot]
    let terminalAttachment: (String) -> DockTerminalAttachment?
    let onFocus: (String) -> Void
    let onRestart: (String) -> Void
    let onKeyboardFocusIntent: (String, NSWindow?) -> Void
    let onTriggerFlash: (String) -> Void

    private let heightLayout = DockTerminalHeightLayout()

    var body: some View {
        GeometryReader { proxy in
            let heights = heightLayout.terminalHeights(availableHeight: proxy.size.height, snapshots: snapshots)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        DockControlSectionView(
                            snapshot: snapshot,
                            ordinal: index + 1,
                            terminalHeight: heights[index],
                            onFocus: { onFocus(snapshot.id) },
                            onRestart: { onRestart(snapshot.id) },
                            terminalContent: {
                                if let attachment = terminalAttachment(snapshot.id) {
                                    DockTerminalView(
                                        attachment: attachment,
                                        onKeyboardFocusIntent: { window in onKeyboardFocusIntent(snapshot.id, window) },
                                        onTriggerFlash: { onTriggerFlash(snapshot.id) }
                                    )
                                } else {
                                    Color.clear
                                }
                            }
                        )
                        if index < snapshots.count - 1 {
                            Divider()
                                .frame(height: heightLayout.dividerHeight)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .dockZeroScrollContentMargins()
        }
    }
}

private struct DockControlSectionView<TerminalContent: View>: View {
    let snapshot: DockControlSnapshot
    let ordinal: Int
    let terminalHeight: CGFloat
    let onFocus: () -> Void
    let onRestart: () -> Void
    @ViewBuilder let terminalContent: () -> TerminalContent

    var body: some View {
        VStack(spacing: 0) {
            header
            terminalContent()
                .frame(height: terminalHeight)
                .clipped()
        }
        .accessibilityIdentifier("DockControl.\(snapshot.id)")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(ordinal)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
            Text(snapshot.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(snapshot.command)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                onFocus()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "dock.action.focusControl", defaultValue: "Focus Control"))
            .accessibilityLabel(String(localized: "dock.action.focusControl", defaultValue: "Focus Control"))

            Button {
                onRestart()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "dock.action.restartControl", defaultValue: "Restart Control"))
            .accessibilityLabel(String(localized: "dock.action.restartControl", defaultValue: "Restart Control"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(height: 30)
        .background(Color.primary.opacity(0.035))
    }
}

private struct DockTerminalView: View {
    let attachment: DockTerminalAttachment
    let onKeyboardFocusIntent: (NSWindow?) -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        GhosttyTerminalView(
            terminalSurface: attachment.terminalSurface,
            paneId: attachment.paneId,
            isActive: true,
            isVisibleInUI: true,
            portalZPriority: 1,
            searchState: attachment.searchState,
            reattachToken: attachment.reattachToken,
            onFocus: { _ in
                onKeyboardFocusIntent(attachment.terminalSurface.uiWindow)
            },
            onTriggerFlash: {
                onTriggerFlash()
            }
        )
        .id(attachment.panelId)
        .background(Color.clear)
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
    let store: DockControlsStore

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

final class DockKeyboardFocusView: NSView, DockFocusHosting {
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

private extension View {
    @ViewBuilder
    func dockZeroScrollContentMargins() -> some View {
        if #available(macOS 14.0, *) {
            self.contentMargins(.all, 0, for: .scrollContent)
        } else {
            self
        }
    }
}
