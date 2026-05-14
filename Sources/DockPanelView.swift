import AppKit
import Bonsplit
import SwiftUI

enum DockEntryKind: Equatable {
    case terminal(command: String, cwd: String?, env: [String: String])
    case browser(url: URL?, profile: String?)

    enum Tag: String {
        case terminal
        case browser
    }

    var tag: Tag {
        switch self {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        }
    }

    var symbolName: String {
        switch self {
        case .terminal:
            return "terminal.fill"
        case .browser:
            return "globe"
        }
    }

    var detailText: String {
        switch self {
        case .terminal(let command, _, _):
            return command
        case .browser(let url, _):
            return url?.absoluteString ?? String(localized: "dock.entry.browser.new", defaultValue: "New browser")
        }
    }
}

struct DockControlDefinition: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let height: Double?
    let kind: DockEntryKind

    var command: String {
        switch kind {
        case .terminal(let command, _, _):
            return command
        case .browser:
            return kind.detailText
        }
    }

    init(
        id: String,
        title: String,
        command: String,
        cwd: String? = nil,
        height: Double? = nil,
        env: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.height = height
        self.kind = .terminal(command: command, cwd: cwd, env: env)
    }

    init(
        id: String,
        title: String,
        url: URL? = nil,
        profile: String? = nil,
        height: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.height = height
        self.kind = .browser(url: url, profile: profile)
    }

    private init(id: String, title: String, height: Double?, kind: DockEntryKind) {
        self.id = id
        self.title = title
        self.height = height
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case command
        case cwd
        case height
        case env
        case url
        case profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? rawID
        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: String(localized: "dock.error.blankControlID", defaultValue: "Dock control id must not be blank.")
            )
        }

        let requestedKind = try container.decodeIfPresent(String.self, forKey: .kind)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let resolvedKind: DockEntryKind
        switch requestedKind {
        case nil, "", DockEntryKind.Tag.terminal.rawValue:
            let rawCommand = try container.decode(String.self, forKey: .command)
            let normalizedCommand = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedCommand.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .command,
                    in: container,
                    debugDescription: String(localized: "dock.error.blankControlCommand", defaultValue: "Dock control command must not be blank.")
                )
            }
            let rawCWD = try container.decodeIfPresent(String.self, forKey: .cwd)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedKind = .terminal(
                command: normalizedCommand,
                cwd: rawCWD?.isEmpty == true ? nil : rawCWD,
                env: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
            )
        case DockEntryKind.Tag.browser.rawValue:
            let rawURL = try container.decodeIfPresent(String.self, forKey: .url)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url: URL?
            if let rawURL, !rawURL.isEmpty {
                guard let parsed = URL(string: rawURL) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .url,
                        in: container,
                        debugDescription: String(localized: "dock.error.invalidControlURL", defaultValue: "Dock browser URL is invalid.")
                    )
                }
                url = parsed
            } else {
                url = nil
            }
            let rawProfile = try container.decodeIfPresent(String.self, forKey: .profile)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedKind = .browser(url: url, profile: rawProfile?.isEmpty == true ? nil : rawProfile)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: String(localized: "dock.error.invalidControlKind", defaultValue: "Dock control kind must be terminal or browser.")
            )
        }
        self.init(
            id: normalizedID,
            title: normalizedTitle.isEmpty ? normalizedID : normalizedTitle,
            height: try container.decodeIfPresent(Double.self, forKey: .height),
            kind: resolvedKind
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(height, forKey: .height)
        switch kind {
        case .terminal(let command, let cwd, let env):
            try container.encode(DockEntryKind.Tag.terminal.rawValue, forKey: .kind)
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(cwd, forKey: .cwd)
            if !env.isEmpty {
                try container.encode(env, forKey: .env)
            }
        case .browser(let url, let profile):
            try container.encode(DockEntryKind.Tag.browser.rawValue, forKey: .kind)
            try container.encodeIfPresent(url?.absoluteString, forKey: .url)
            try container.encodeIfPresent(profile, forKey: .profile)
        }
    }
}

private struct DockConfigFile: Codable {
    let controls: [DockControlDefinition]
}

private struct DockConfigResolution {
    let controls: [DockControlDefinition]
    let sourceURL: URL?
    let baseDirectory: String
    let isProjectSource: Bool
}

struct DockTrustRequest: Identifiable {
    var id: String { descriptor.fingerprint }
    let descriptor: CmuxActionTrustDescriptor
    let configPath: String
}

private enum DockControlRuntimeError: LocalizedError {
    case browserUnavailable
    case browserWorkspaceUnavailable

    var errorDescription: String? {
        switch self {
        case .browserUnavailable:
            return String(
                localized: "dock.error.browserUnavailable",
                defaultValue: "Dock browser entries require the embedded browser to be enabled."
            )
        case .browserWorkspaceUnavailable:
            return String(
                localized: "dock.error.browserWorkspaceUnavailable",
                defaultValue: "Dock browser entry could not find its workspace."
            )
        }
    }
}

@MainActor
final class DockControlRuntime: ObservableObject, Identifiable {
    let id: String
    private(set) var definition: DockControlDefinition?
    private var detachedTransfer: Workspace.DetachedSurfaceTransfer?
    let baseDirectory: String
    let workspaceId: UUID
    let paneId: PaneID
    @Published private(set) var panel: any Panel

    init(definition: DockControlDefinition, baseDirectory: String, workspaceId: UUID) throws {
        self.id = definition.id
        self.definition = definition
        self.detachedTransfer = nil
        self.baseDirectory = baseDirectory
        self.workspaceId = workspaceId
        self.paneId = PaneID(id: UUID())
        self.panel = try Self.makePanel(definition: definition, baseDirectory: baseDirectory, workspaceId: workspaceId)
    }

    init(detached transfer: Workspace.DetachedSurfaceTransfer, baseDirectory: String, workspaceId: UUID) {
        self.id = "docked-\(transfer.panelId.uuidString.lowercased())"
        self.definition = nil
        self.detachedTransfer = transfer
        self.baseDirectory = baseDirectory
        self.workspaceId = workspaceId
        self.paneId = PaneID(id: UUID())
        self.panel = transfer.panel
        Self.prepareTransferredPanel(transfer.panel, workspaceId: workspaceId)
    }

    fileprivate var snapshot: DockControlSnapshot {
        if let definition {
            return .init(
                id: id,
                title: definition.title,
                detail: definition.kind.detailText,
                symbolName: definition.kind.symbolName,
                kind: definition.kind.tag,
                requestedHeight: definition.height,
                canRestart: true
            )
        }

        return .init(
            id: id,
            title: detachedTransfer?.title ?? panel.displayTitle,
            detail: panelDetailText,
            symbolName: panel.displayIcon ?? "dock.rectangle",
            kind: panel.panelType == .browser ? .browser : .terminal,
            requestedHeight: nil,
            canRestart: false
        )
    }

    fileprivate var terminalAttachment: DockTerminalAttachment? {
        guard let terminalPanel = panel as? TerminalPanel else { return nil }
        return .init(
            paneId: paneId,
            panelId: terminalPanel.id,
            terminalSurface: terminalPanel.surface,
            searchState: terminalPanel.searchState,
            reattachToken: terminalPanel.viewReattachToken
        )
    }

    fileprivate var browserAttachment: DockBrowserAttachment? {
        guard let browserPanel = panel as? BrowserPanel else { return nil }
        return DockBrowserAttachment(paneId: paneId, panel: browserPanel)
    }

    fileprivate var panelID: UUID { panel.id }

    func focus() {
        switch panel {
        case let terminalPanel as TerminalPanel:
            terminalPanel.hostedView.ensureFocus(
                for: terminalPanel.surface.tabId,
                surfaceId: terminalPanel.id,
                respectForeignFirstResponder: false
            )
        case let browserPanel as BrowserPanel:
            _ = browserPanel.requestExplicitWebViewFocus()
        default:
            break
        }
    }

    func restart() throws {
        guard let definition else { return }
        let oldPanel = panel
        panel = try Self.makePanel(definition: definition, baseDirectory: baseDirectory, workspaceId: workspaceId)
        oldPanel.close()
    }

    func close() {
        panel.close()
    }

    func setVisibleInUI(_ visible: Bool) {
        switch panel {
        case let terminalPanel as TerminalPanel:
            if visible {
                terminalPanel.hostedView.setVisibleInUI(true)
                TerminalWindowPortalRegistry.updateEntryVisibility(
                    for: terminalPanel.hostedView,
                    visibleInUI: true
                )
            } else {
                terminalPanel.unfocus()
                terminalPanel.hostedView.setVisibleInUI(false)
                TerminalWindowPortalRegistry.hideHostedView(terminalPanel.hostedView)
            }
        case let browserPanel as BrowserPanel:
            if visible {
                BrowserWindowPortalRegistry.updateEntryVisibility(
                    for: browserPanel.webView,
                    visibleInUI: true,
                    zPriority: 1
                )
            } else {
                browserPanel.unfocus()
                BrowserWindowPortalRegistry.updateEntryVisibility(
                    for: browserPanel.webView,
                    visibleInUI: false,
                    zPriority: 0
                )
                BrowserWindowPortalRegistry.hide(webView: browserPanel.webView, source: "dock.hidden")
            }
        default:
            break
        }
    }

    func detachedSurfaceTransferForDrag() -> Workspace.DetachedSurfaceTransfer {
        let browserPanel = panel as? BrowserPanel
        let terminalPanel = panel as? TerminalPanel
        let preserved = detachedTransfer
        return Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: preserved?.sourceWorkspaceId ?? workspaceId,
            panelId: panel.id,
            panel: panel,
            title: snapshot.title,
            icon: panel.displayIcon,
            iconImageData: browserPanel?.faviconPNGData ?? preserved?.iconImageData,
            kind: Self.surfaceKind(for: panel),
            isLoading: browserPanel?.isLoading ?? preserved?.isLoading ?? false,
            isPinned: preserved?.isPinned ?? false,
            directory: preserved?.directory ?? terminalPanel?.requestedWorkingDirectory,
            ttyName: preserved?.ttyName,
            cachedTitle: preserved?.cachedTitle,
            customTitle: preserved?.customTitle,
            manuallyUnread: preserved?.manuallyUnread ?? false,
            restoredUnread: preserved?.restoredUnread ?? false,
            restorableAgent: preserved?.restorableAgent,
            restorableAgentResumeState: preserved?.restorableAgentResumeState,
            agentRuntime: preserved?.agentRuntime,
            isRemoteTerminal: preserved?.isRemoteTerminal ?? false,
            remoteRelayPort: preserved?.remoteRelayPort,
            remoteCleanupConfiguration: preserved?.remoteCleanupConfiguration
        )
    }

    func triggerFlash() {
        if let terminalPanel = panel as? TerminalPanel {
            terminalPanel.triggerFlash(reason: .debug)
        } else if let browserPanel = panel as? BrowserPanel {
            browserPanel.triggerFlash(reason: .debug)
        }
    }

    private static func makePanel(
        definition: DockControlDefinition,
        baseDirectory: String,
        workspaceId: UUID
    ) throws -> any Panel {
        switch definition.kind {
        case .terminal(let command, let cwd, let env):
            var environment = env
            environment["CMUX_DOCK_CONTROL_ID"] = definition.id
            environment["CMUX_DOCK_CONTROL_TITLE"] = definition.title

            let workingDirectory = resolvedWorkingDirectory(cwd, baseDirectory: baseDirectory)
            return TerminalPanel(
                workspaceId: workspaceId,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                workingDirectory: workingDirectory,
                initialCommand: shellStartupScript(
                    command: command,
                    workingDirectory: workingDirectory
                ),
                initialEnvironmentOverrides: environment,
                focusPlacement: .rightSidebarDock
            )
        case .browser(let url, let profile):
            guard let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?
                .tabs
                .first(where: { $0.id == workspaceId }) else {
#if DEBUG
                cmuxDebugLog("dock.browser.create.blocked id=\(definition.id) reason=missing_workspace")
#endif
                throw DockControlRuntimeError.browserWorkspaceUnavailable
            }
            guard let panel = workspace.newDockBrowserPanel(
                url: url,
                preferredProfileID: browserProfileID(for: profile)
            ) else {
#if DEBUG
                cmuxDebugLog("dock.browser.create.blocked id=\(definition.id) reason=browser_unavailable")
#endif
                throw DockControlRuntimeError.browserUnavailable
            }
            return panel
        }
    }

    private static func prepareTransferredPanel(_ panel: any Panel, workspaceId: UUID) {
        if let terminalPanel = panel as? TerminalPanel {
            terminalPanel.updateWorkspaceId(workspaceId)
            terminalPanel.unfocus()
            terminalPanel.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(terminalPanel.hostedView)
        } else if let browserPanel = panel as? BrowserPanel {
            browserPanel.updateWorkspaceId(workspaceId)
            browserPanel.unfocus()
            BrowserWindowPortalRegistry.updateEntryVisibility(
                for: browserPanel.webView,
                visibleInUI: false,
                zPriority: 0
            )
            BrowserWindowPortalRegistry.hide(webView: browserPanel.webView, source: "dock.transferIn")
        }
    }

    private static func browserProfileID(for profile: String?) -> UUID? {
        guard let raw = profile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let store = BrowserProfileStore.shared
        if raw.caseInsensitiveCompare("default") == .orderedSame {
            return store.builtInDefaultProfileID
        }
        if let uuid = UUID(uuidString: raw),
           store.profileDefinition(id: uuid) != nil {
            return uuid
        }
        return store.profiles.first {
            $0.slug.caseInsensitiveCompare(raw) == .orderedSame ||
                $0.displayName.caseInsensitiveCompare(raw) == .orderedSame
        }?.id
    }

    private static func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return Workspace.SurfaceKind.terminal
        case .browser:
            return Workspace.SurfaceKind.browser
        case .markdown:
            return Workspace.SurfaceKind.markdown
        case .filePreview:
            return Workspace.SurfaceKind.filePreview
        case .rightSidebarTool:
            return Workspace.SurfaceKind.rightSidebarTool
        }
    }

    private var panelDetailText: String {
        if let terminalPanel = panel as? TerminalPanel {
            return terminalPanel.displayTitle
        }
        if let browserPanel = panel as? BrowserPanel {
            return browserPanel.currentURL?.absoluteString
                ?? String(localized: "dock.entry.browser.new", defaultValue: "New browser")
        }
        return panel.displayTitle
    }

    private static func resolvedWorkingDirectory(_ cwd: String?, baseDirectory: String) -> String {
        guard let cwd, !cwd.isEmpty else { return baseDirectory }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseDirectory as NSString).appendingPathComponent(cwd)
    }

    private static func shellStartupScript(command: String, workingDirectory: String) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-dock-control-\(UUID().uuidString.lowercased()).sh"
        )
        let encodedCommand = Data(command.utf8).base64EncodedString()
        let encodedWorkingDirectory = Data(workingDirectory.utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        cmux_dock_decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
        cmux_dock_login_shell() {
          cmux_dock_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
          cmux_dock_ds_shell="$(dscl . -read "/Users/$cmux_dock_user" UserShell 2>/dev/null | awk '{print $2; exit}')"
          if [ -n "$cmux_dock_ds_shell" ] && [ -x "$cmux_dock_ds_shell" ]; then printf '%s\\n' "$cmux_dock_ds_shell"
          elif [ -n "${SHELL:-}" ] && [ -x "${SHELL:-}" ]; then printf '%s\\n' "$SHELL"
          else printf '%s\\n' /bin/sh; fi
        }
        cmux_dock_command="$(cmux_dock_decode '\(encodedCommand)')"
        cmux_dock_working_directory="$(cmux_dock_decode '\(encodedWorkingDirectory)')"
        cmux_dock_shell="$(cmux_dock_login_shell)"
        cmux_dock_bundle_bin=""
        if [ -n "${CMUX_BUNDLED_CLI_PATH:-}" ]; then cmux_dock_bundle_bin="$(dirname "$CMUX_BUNDLED_CLI_PATH")"; fi
        export SHELL="$cmux_dock_shell"
        rm -f -- "$0" 2>/dev/null || true
        case "$(basename "$cmux_dock_shell")" in
          fish)
            CMUX_DOCK_BUNDLE_BIN="$cmux_dock_bundle_bin" CMUX_DOCK_START_COMMAND="$cmux_dock_command" CMUX_DOCK_START_DIRECTORY="$cmux_dock_working_directory" "$cmux_dock_shell" -l -c 'if test -n "$CMUX_DOCK_BUNDLE_BIN"; and not contains -- "$CMUX_DOCK_BUNDLE_BIN" $PATH; set -gx PATH "$CMUX_DOCK_BUNDLE_BIN" $PATH; end; if test -n "$CMUX_DOCK_START_DIRECTORY"; cd "$CMUX_DOCK_START_DIRECTORY"; end; eval "$CMUX_DOCK_START_COMMAND"'
            ;;
          *) CMUX_DOCK_BUNDLE_BIN="$cmux_dock_bundle_bin" CMUX_DOCK_START_COMMAND="$cmux_dock_command" CMUX_DOCK_START_DIRECTORY="$cmux_dock_working_directory" "$cmux_dock_shell" -lc 'if [ -n "${CMUX_DOCK_BUNDLE_BIN:-}" ]; then case ":${PATH:-}:" in *":$CMUX_DOCK_BUNDLE_BIN:"*) ;; *) PATH="$CMUX_DOCK_BUNDLE_BIN${PATH:+:$PATH}"; export PATH ;; esac; fi; cd "$CMUX_DOCK_START_DIRECTORY" 2>/dev/null || true; eval "$CMUX_DOCK_START_COMMAND"'
            ;;
        esac
        printf '\\n'
        exec "$cmux_dock_shell" -l
        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return "/bin/sh"
        }
    }

}

fileprivate struct DockControlSnapshot: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbolName: String
    let kind: DockEntryKind.Tag
    let requestedHeight: Double?
    let canRestart: Bool
}

fileprivate struct DockTerminalAttachment { let paneId: PaneID; let panelId: UUID; let terminalSurface: TerminalSurface; let searchState: TerminalSurface.SearchState?; let reattachToken: UInt64 }
fileprivate struct DockBrowserAttachment { let paneId: PaneID; let panel: BrowserPanel }

private struct DockMirrorTabItem: Codable {
    let id: UUID
    let title: String
    let hasCustomTitle: Bool
    let icon: String?
    let iconImageData: Data?
    let kind: String?
    let isDirty: Bool
    let showsNotificationBadge: Bool
    let isLoading: Bool
    let isPinned: Bool
}

private struct DockMirrorTabTransferData: Codable {
    let tab: DockMirrorTabItem
    let sourcePaneId: UUID
    let sourceProcessId: Int32
}

struct DockSurfaceDragEntry {
    let transfer: Workspace.DetachedSurfaceTransfer
    let onAttached: @MainActor () -> Void
}

@MainActor
final class DockSurfaceDragRegistry {
    static let shared = DockSurfaceDragRegistry()

    private struct PendingDrag {
        let entry: DockSurfaceDragEntry
        let expirationTimer: Timer
    }

    private let entryLifetime: TimeInterval = 60
    private var pending: [UUID: PendingDrag] = [:]

    func register(
        transfer: Workspace.DetachedSurfaceTransfer,
        onAttached: @escaping @MainActor () -> Void
    ) -> UUID {
        let id = UUID()
        let timer = Timer(timeInterval: entryLifetime, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.expire(id: id)
            }
        }
        pending[id] = PendingDrag(
            entry: DockSurfaceDragEntry(transfer: transfer, onAttached: onAttached),
            expirationTimer: timer
        )
        RunLoop.main.add(timer, forMode: .common)
        return id
    }

    func consume(id: UUID) -> DockSurfaceDragEntry? {
        guard let drag = pending.removeValue(forKey: id) else { return nil }
        drag.expirationTimer.invalidate()
        return drag.entry
    }

    private func expire(id: UUID) {
        pending.removeValue(forKey: id)?.expirationTimer.invalidate()
    }
}

@MainActor
final class DockControlsStore: ObservableObject {
    @Published private(set) var controls: [DockControlRuntime] = []
    @Published private(set) var sourceLabel = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var trustRequest: DockTrustRequest?

    private var lastRootDirectory: String?
    private var lastWorkspaceId: UUID?
    private var activeConfigURL: URL?
    private var hasLoadedConfiguration = false
    private var controlsVisibleInUI = false
    private var focusedControlID: String?

    fileprivate var controlSnapshots: [DockControlSnapshot] {
        controls.map(\.snapshot)
    }

    fileprivate func terminalAttachment(for controlID: String) -> DockTerminalAttachment? {
        controls.first { $0.id == controlID }?.terminalAttachment
    }

    fileprivate func browserAttachment(for controlID: String) -> DockBrowserAttachment? {
        controls.first { $0.id == controlID }?.browserAttachment
    }

    fileprivate func isFocused(controlID: String) -> Bool {
        focusedControlID == controlID
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
            let resolution = try Self.resolve(rootDirectory: rootDirectory)
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
            var resolvedControls: [DockControlRuntime] = []
            var firstRuntimeError: Error?
            for definition in resolution.controls {
                do {
                    resolvedControls.append(try DockControlRuntime(
                        definition: definition,
                        baseDirectory: resolution.baseDirectory,
                        workspaceId: workspaceId
                    ))
                } catch {
                    firstRuntimeError = firstRuntimeError ?? error
#if DEBUG
                    cmuxDebugLog("dock.config.entry.skip id=\(definition.id) error=\(error.localizedDescription)")
#endif
                }
            }
            if resolvedControls.isEmpty, let firstRuntimeError {
                throw firstRuntimeError
            }
            replaceControls(with: resolvedControls)
            sourceLabel = Self.sourceLabel(for: resolution)
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
        focusedControlID = first.id
        first.focus()
        return true
    }

    func openConfiguration() {
        do {
            let target: URL
            if let activeConfigURL {
                target = activeConfigURL
            } else {
                target = try Self.preferredEditableConfigURL(rootDirectory: lastRootDirectory)
            }
            if !FileManager.default.fileExists(atPath: target.path) {
                try Self.writeTemplate(to: target)
            }
            NSWorkspace.shared.open(target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func focusControl(id: String) {
        focusedControlID = id
        controls.first { $0.id == id }?.focus()
    }

    func restartControl(id: String) {
        guard let index = controls.firstIndex(where: { $0.id == id }) else { return }
        let oldControl = controls[index]
        guard let definition = oldControl.definition else { return }
        do {
            let newControl = try DockControlRuntime(
                definition: definition,
                baseDirectory: oldControl.baseDirectory,
                workspaceId: oldControl.workspaceId
            )
            controls[index] = newControl
            newControl.setVisibleInUI(controlsVisibleInUI)
            oldControl.close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func noteKeyboardFocusIntent(id: String, window: NSWindow?) {
        guard controls.contains(where: { $0.id == id }) else { return }
        AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
    }

    func triggerFlash(id: String) {
        controls.first { $0.id == id }?.triggerFlash()
    }

    func addTerminal() {
        guard let workspaceId = lastWorkspaceId else { return }
        let title = String(localized: "dock.entry.terminal.defaultTitle", defaultValue: "Terminal")
        let definition = DockControlDefinition(
            id: uniqueControlID(prefix: "terminal"),
            title: title,
            command: ":",
            cwd: nil,
            height: 240,
            env: [:]
        )
        do {
            let control = try DockControlRuntime(
                definition: definition,
                baseDirectory: currentBaseDirectory(),
                workspaceId: workspaceId
            )
            errorMessage = nil
            appendControl(control)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addBrowser() {
        guard let workspaceId = lastWorkspaceId else { return }
        let title = String(localized: "dock.entry.browser.defaultTitle", defaultValue: "Browser")
        let definition = DockControlDefinition(
            id: uniqueControlID(prefix: "browser"),
            title: title,
            url: nil,
            profile: nil,
            height: 320
        )
        do {
            let control = try DockControlRuntime(
                definition: definition,
                baseDirectory: currentBaseDirectory(),
                workspaceId: workspaceId
            )
            errorMessage = nil
            appendControl(control)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func dockCurrentPane() -> Bool {
        guard let workspaceId = lastWorkspaceId,
              let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }),
              let panelId = workspace.focusedPanelId else {
            return false
        }
        return dockPanel(panelId: panelId, workspace: workspace)
    }

    @discardableResult
    func dockBonsplitTransfer(_ transfer: BonsplitTabDragPayload.Transfer) -> Bool {
        guard let located = AppDelegate.shared?.locateBonsplitSurface(tabId: transfer.tab.id),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
            return false
        }
        return dockPanel(panelId: located.panelId, workspace: workspace)
    }

    func dragItemProvider(for controlID: String) -> NSItemProvider {
        guard let control = controls.first(where: { $0.id == controlID }) else {
            return NSItemProvider()
        }
        let transfer = control.detachedSurfaceTransferForDrag()
        let dragId = DockSurfaceDragRegistry.shared.register(
            transfer: transfer,
            onAttached: { [weak self] in
                self?.removeControl(id: controlID, closePanel: false)
            }
        )
        let provider = NSItemProvider()
        if let data = Self.tabTransferData(
            dragId: dragId,
            title: control.snapshot.title,
            icon: control.snapshot.symbolName,
            iconImageData: transfer.iconImageData,
            kind: transfer.kind,
            isDirty: transfer.panel.isDirty,
            isLoading: transfer.isLoading,
            isPinned: transfer.isPinned,
            sourcePaneId: control.paneId.id
        ) {
            provider.registerDataRepresentation(
                forTypeIdentifier: BonsplitTabDragPayload.typeIdentifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
            let pasteboard = NSPasteboard(name: .drag)
            let type = NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)
            pasteboard.addTypes([type], owner: nil)
            pasteboard.setData(data, forType: type)
        }
        provider.suggestedName = control.snapshot.title
        return provider
    }

    func ownsBrowserKeyboardFocus(_ responder: NSResponder) -> Bool {
        controls.contains { control in
            guard let browser = control.browserAttachment?.panel else { return false }
            return Self.responderChainContains(responder, target: browser.webView)
        }
    }

    private func replaceControls(with newControls: [DockControlRuntime]) {
        let oldControls = controls
        controls = newControls
        if let focusedControlID, !newControls.contains(where: { $0.id == focusedControlID }) {
            self.focusedControlID = nil
        }
        newControls.forEach { $0.setVisibleInUI(controlsVisibleInUI) }
        oldControls.forEach { $0.close() }
    }

    private func setControlsVisibleInUI(_ visible: Bool) {
        controls.forEach { $0.setVisibleInUI(visible) }
    }

    private func appendControl(_ control: DockControlRuntime) {
        controls.append(control)
        control.setVisibleInUI(controlsVisibleInUI)
        focusedControlID = control.id
        control.focus()
    }

    private func removeControl(id: String, closePanel: Bool) {
        guard let index = controls.firstIndex(where: { $0.id == id }) else { return }
        let removed = controls.remove(at: index)
        if focusedControlID == id {
            focusedControlID = nil
        }
        if closePanel {
            removed.close()
        }
    }

    private func dockPanel(panelId: UUID, workspace: Workspace) -> Bool {
        guard let panel = workspace.panels[panelId],
              panel.panelType == .terminal || panel.panelType == .browser else {
            return false
        }
        guard let detached = workspace.detachSurface(panelId: panelId) else { return false }
        if workspace.panels.isEmpty,
           let fallbackPane = workspace.bonsplitController.allPaneIds.first {
            _ = workspace.newTerminalSurface(inPane: fallbackPane, focus: true)
        }
        let control = DockControlRuntime(
            detached: detached,
            baseDirectory: currentBaseDirectory(),
            workspaceId: lastWorkspaceId ?? workspace.id
        )
        appendControl(control)
        return true
    }

    private func currentBaseDirectory() -> String {
        lastRootDirectory.flatMap(Self.existingDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func uniqueControlID(prefix: String) -> String {
        let existing = Set(controls.map(\.id))
        var index = controls.count + 1
        while true {
            let candidate = "\(prefix)-\(index)"
            if !existing.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }

    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var current: NSResponder? = start
        var hops = 0
        while let responder = current, hops < 64 {
            if responder === target { return true }
            current = responder.nextResponder
            hops += 1
        }
        return false
    }

    private static func tabTransferData(
        dragId: UUID,
        title: String,
        icon: String?,
        iconImageData: Data?,
        kind: String?,
        isDirty: Bool,
        isLoading: Bool,
        isPinned: Bool,
        sourcePaneId: UUID
    ) -> Data? {
        let transfer = DockMirrorTabTransferData(
            tab: DockMirrorTabItem(
                id: dragId,
                title: title,
                hasCustomTitle: false,
                icon: icon,
                iconImageData: iconImageData,
                kind: kind,
                isDirty: isDirty,
                showsNotificationBadge: false,
                isLoading: isLoading,
                isPinned: isPinned
            ),
            sourcePaneId: sourcePaneId,
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )
        return try? JSONEncoder().encode(transfer)
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

    private static func resolve(rootDirectory: String?) throws -> DockConfigResolution {
        if let projectURL = projectConfigURL(rootDirectory: rootDirectory) {
            return try loadConfig(
                from: projectURL,
                baseDirectory: projectBaseDirectory(for: projectURL),
                isProjectSource: true
            )
        }

        let globalURL = globalConfigURL()
        if FileManager.default.fileExists(atPath: globalURL.path) {
            return try loadConfig(
                from: globalURL,
                baseDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                isProjectSource: false
            )
        }

        return DockConfigResolution(
            controls: [],
            sourceURL: nil,
            baseDirectory: rootDirectory.flatMap(Self.existingDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path,
            isProjectSource: false
        )
    }

    private static func loadConfig(
        from url: URL,
        baseDirectory: String,
        isProjectSource: Bool
    ) throws -> DockConfigResolution {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(DockConfigFile.self, from: data)
        var seen = Set<String>()
        for control in file.controls {
            guard seen.insert(control.id).inserted else {
                throw NSError(
                    domain: "cmux.dock",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "dock.error.duplicateControl",
                            defaultValue: "Dock control ids must be unique."
                        )
                    ]
                )
            }
        }
        return DockConfigResolution(
            controls: file.controls,
            sourceURL: url,
            baseDirectory: baseDirectory,
            isProjectSource: isProjectSource
        )
    }

    private static func sourceLabel(for resolution: DockConfigResolution) -> String {
        if resolution.sourceURL == nil {
            return String(localized: "dock.source.title", defaultValue: "Dock")
        }
        return resolution.isProjectSource
            ? String(localized: "dock.source.project", defaultValue: "Project Dock")
            : String(localized: "dock.source.global", defaultValue: "Global Dock")
    }

    private static func projectConfigURL(rootDirectory: String?) -> URL? {
        guard let rootDirectory = rootDirectory.flatMap(existingDirectory) else { return nil }
        var candidate = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        while true {
            let configURL = candidate
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("dock.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: configURL.path) {
                return configURL
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path || candidate.path == homePath {
                return nil
            }
            candidate = parent
        }
    }

    private static func projectBaseDirectory(for configURL: URL) -> String {
        let cmuxDirectory = configURL.deletingLastPathComponent()
        return cmuxDirectory.deletingLastPathComponent().path
    }

    private static func globalConfigURL() -> URL {
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1",
           let testPath = ProcessInfo.processInfo.environment["CMUX_UI_TEST_DOCK_CONFIG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !testPath.isEmpty {
            return URL(fileURLWithPath: testPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/dock.json", isDirectory: false)
    }

    private static func preferredEditableConfigURL(rootDirectory: String?) throws -> URL {
        if let rootDirectory = rootDirectory.flatMap(existingDirectory) {
            return URL(fileURLWithPath: rootDirectory, isDirectory: true)
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("dock.json", isDirectory: false)
        }
        return globalConfigURL()
    }

    private static func existingDirectory(_ rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? expanded : (expanded as NSString).deletingLastPathComponent
    }

    private static func writeTemplate(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = DockConfigFile(controls: [
            DockControlDefinition(
                id: "git",
                title: "Git",
                command: "lazygit",
                height: 300
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
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
            configPath: resolution.sourceURL.map { canonicalPath($0.path) },
            projectRoot: canonicalPath(resolution.baseDirectory),
            iconFingerprint: nil
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }
}

struct DockPanelView: View {
    let rootDirectory: String?
    let workspaceId: UUID?
    @ObservedObject var store: DockControlsStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear {
            store.activate(rootDirectory: rootDirectory, workspaceId: workspaceId)
        }
        .onDisappear {
            store.deactivate()
        }
        .onChange(of: rootDirectory) { _, newValue in
            store.activate(rootDirectory: newValue, workspaceId: workspaceId)
        }
        .onChange(of: workspaceId) { _, newValue in
            store.activate(rootDirectory: rootDirectory, workspaceId: newValue)
        }
        .background(
            DockKeyboardFocusBridge(store: store)
                .frame(width: 1, height: 1)
        )
        .onDrop(of: BonsplitTabDragPayload.dropContentTypes, delegate: DockBonsplitTabDropDelegate(store: store))
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
            Menu {
                Button {
                    store.addTerminal()
                } label: {
                    Label(
                        String(localized: "dock.action.addTerminal", defaultValue: "Add terminal"),
                        systemImage: "terminal.fill"
                    )
                }
                Button {
                    store.addBrowser()
                } label: {
                    Label(
                        String(localized: "dock.action.addBrowser", defaultValue: "Add browser"),
                        systemImage: "globe"
                    )
                }
                Divider()
                Button {
                    _ = store.dockCurrentPane()
                } label: {
                    Label(
                        String(localized: "dock.action.dockCurrentPane", defaultValue: "Dock current pane"),
                        systemImage: "dock.rectangle"
                    )
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "dock.action.add", defaultValue: "Add Dock Entry"))
            .accessibilityLabel(String(localized: "dock.action.add", defaultValue: "Add Dock Entry"))

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
                browserAttachment: { id in store.browserAttachment(for: id) },
                isFocused: { id in store.isFocused(controlID: id) },
                onFocus: { id in store.focusControl(id: id) },
                onRestart: { id in store.restartControl(id: id) },
                onKeyboardFocusIntent: { id, window in store.noteKeyboardFocusIntent(id: id, window: window) },
                onTriggerFlash: { id in store.triggerFlash(id: id) },
                onDragProvider: { id in store.dragItemProvider(for: id) }
            )
        }
    }
}

private struct DockControlsLayoutView: View {
    let snapshots: [DockControlSnapshot]
    let terminalAttachment: (String) -> DockTerminalAttachment?
    let browserAttachment: (String) -> DockBrowserAttachment?
    let isFocused: (String) -> Bool
    let onFocus: (String) -> Void
    let onRestart: (String) -> Void
    let onKeyboardFocusIntent: (String, NSWindow?) -> Void
    let onTriggerFlash: (String) -> Void
    let onDragProvider: (String) -> NSItemProvider

    private let headerHeight: CGFloat = 30
    private let dividerHeight: CGFloat = 1
    private let minimumEntryHeight: CGFloat = 160

    var body: some View {
        GeometryReader { proxy in
            let heights = entryHeights(availableHeight: proxy.size.height)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        DockControlSectionView(
                            snapshot: snapshot,
                            ordinal: index + 1,
                            entryHeight: heights[index],
                            onFocus: { onFocus(snapshot.id) },
                            onRestart: { onRestart(snapshot.id) },
                            entryContent: {
                                if snapshot.kind == .terminal,
                                   let attachment = terminalAttachment(snapshot.id) {
                                    DockTerminalView(
                                        attachment: attachment,
                                        onKeyboardFocusIntent: { window in onKeyboardFocusIntent(snapshot.id, window) },
                                        onTriggerFlash: { onTriggerFlash(snapshot.id) }
                                    )
                                } else if snapshot.kind == .browser,
                                          let attachment = browserAttachment(snapshot.id) {
                                    DockBrowserView(
                                        attachment: attachment,
                                        isFocused: isFocused(snapshot.id),
                                        onRequestPanelFocus: { onFocus(snapshot.id) }
                                    )
                                } else {
                                    Color.clear
                                }
                            }
                        )
                        .onDrag { onDragProvider(snapshot.id) }
                        if index < snapshots.count - 1 {
                            Divider()
                                .frame(height: dividerHeight)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .dockZeroScrollContentMargins()
        }
    }

    private func entryHeights(availableHeight: CGFloat) -> [CGFloat] {
        guard !snapshots.isEmpty else { return [] }

        let chromeHeight = CGFloat(snapshots.count) * headerHeight
            + CGFloat(max(snapshots.count - 1, 0)) * dividerHeight
        let availableEntryHeight = max(availableHeight - chromeHeight, 0)
        var heights = Array(repeating: CGFloat.zero, count: snapshots.count)
        var flexibleIndexes: [Int] = []
        var fixedHeightTotal: CGFloat = 0

        for (index, snapshot) in snapshots.enumerated() {
            if let requestedHeight = snapshot.requestedHeight {
                let fixedHeight = max(CGFloat(requestedHeight), minimumEntryHeight)
                heights[index] = fixedHeight
                fixedHeightTotal += fixedHeight
            } else {
                flexibleIndexes.append(index)
            }
        }

        if flexibleIndexes.isEmpty {
            let extraHeight = max(availableEntryHeight - fixedHeightTotal, 0)
            guard extraHeight > 0 else { return heights }
            let extraHeightPerControl = extraHeight / CGFloat(snapshots.count)
            return heights.map { $0 + extraHeightPerControl }
        }

        let remaining = max(availableEntryHeight - fixedHeightTotal, 0)
        let sharedHeight = max(remaining / CGFloat(flexibleIndexes.count), minimumEntryHeight)
        for index in flexibleIndexes {
            heights[index] = sharedHeight
        }

        return heights
    }
}

private struct DockControlSectionView<EntryContent: View>: View {
    let snapshot: DockControlSnapshot
    let ordinal: Int
    let entryHeight: CGFloat
    let onFocus: () -> Void
    let onRestart: () -> Void
    @ViewBuilder let entryContent: () -> EntryContent

    var body: some View {
        VStack(spacing: 0) {
            header
            entryContent()
                .frame(height: entryHeight)
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
            Image(systemName: snapshot.symbolName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 13, alignment: .center)
            Text(snapshot.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(snapshot.detail)
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
            .help(String(localized: "dock.action.focusEntry", defaultValue: "Focus Entry"))
            .accessibilityLabel(String(localized: "dock.action.focusEntry", defaultValue: "Focus Entry"))

            if snapshot.canRestart {
                Button {
                    onRestart()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(String(localized: "dock.action.restartEntry", defaultValue: "Restart Entry"))
                .accessibilityLabel(String(localized: "dock.action.restartEntry", defaultValue: "Restart Entry"))
            }
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
                onKeyboardFocusIntent(attachment.terminalSurface.hostedView.window)
            },
            onTriggerFlash: {
                onTriggerFlash()
            }
        )
        .id(attachment.panelId)
        .background(Color.clear)
    }
}

private struct DockBrowserView: View {
    let attachment: DockBrowserAttachment
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        BrowserPanelView(
            panel: attachment.panel,
            paneId: attachment.paneId,
            isFocused: isFocused,
            isVisibleInUI: true,
            portalPriority: 1,
            onRequestPanelFocus: onRequestPanelFocus,
            paneDropContextOverride: BrowserPaneDropContext(
                workspaceId: attachment.panel.workspaceId,
                panelId: attachment.panel.id,
                paneId: attachment.paneId
            ),
            isPanelFocusedInModelOverride: isFocused,
            allowsPaneDropRouting: false
        )
        .id(attachment.panel.id)
        .background(Color.clear)
    }
}

private struct DockBonsplitTabDropDelegate: DropDelegate {
    let store: DockControlsStore

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [BonsplitTabDragPayload.typeIdentifier]) else { return false }
        return BonsplitTabDragPayload.currentTransfer() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .move) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let transfer = BonsplitTabDragPayload.currentTransfer() else {
            return false
        }
        return store.dockBonsplitTransfer(transfer)
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
                defaultValue: "This project wants to start entries from its Dock config."
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
    @ObservedObject var store: DockControlsStore

    func makeNSView(context: Context) -> DockKeyboardFocusView {
        DockKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ nsView: DockKeyboardFocusView, context: Context) {
        nsView.focusFirstControl = { [weak store] in
            store?.focusFirstControl() == true
        }
        nsView.ownsBrowserKeyboardFocus = { [weak store] responder in
            store?.ownsBrowserKeyboardFocus(responder) == true
        }
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class DockKeyboardFocusView: NSView {
    var focusFirstControl: (() -> Bool)?
    var ownsBrowserKeyboardFocus: ((NSResponder) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerWithKeyboardFocusCoordinatorIfNeeded() }

    func registerWithKeyboardFocusCoordinatorIfNeeded() { if let window { AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerDockHost(self) } }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if ownsBrowserKeyboardFocus?(responder) == true {
            return true
        }
        if responder === self { return true }
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let surfaceId = ghosttyView.terminalSurface?.id else {
            return false
        }
        return TerminalSurfaceRegistry.shared.isRightSidebarDockSurface(id: surfaceId)
    }

    func focusFirstItemFromCoordinator() { _ = focusFirstControl?() }

    func focusHostFromCoordinator() -> Bool {
        focusFirstControl?() == true || window?.makeFirstResponder(self) == true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { handleModeShortcut(event) || super.performKeyEquivalent(with: event) }

    override func keyDown(with event: NSEvent) { if !handleModeShortcut(event) { super.keyDown(with: event) } }

    private func handleModeShortcut(_ event: NSEvent) -> Bool {
        guard let mode = RightSidebarMode.modeShortcut(for: event) else { return false }
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
