import AppKit
import CmuxSidebar
import CmuxTerminal
import Bonsplit
import Observation
import SwiftUI

struct DockControlDefinition: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let command: String
    let cwd: String?
    let height: Double?
    let env: [String: String]

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
        self.command = command
        self.cwd = cwd
        self.height = height
        self.env = env
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case command
        case cwd
        case height
        case env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? rawID
        let rawCommand = try container.decode(String.self, forKey: .command)
        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: String(localized: "dock.error.blankControlID", defaultValue: "Dock control id must not be blank.")
            )
        }
        guard !normalizedCommand.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .command,
                in: container,
                debugDescription: String(localized: "dock.error.blankControlCommand", defaultValue: "Dock control command must not be blank.")
            )
        }
        id = normalizedID
        title = normalizedTitle.isEmpty ? normalizedID : normalizedTitle
        command = normalizedCommand
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(height, forKey: .height)
        if !env.isEmpty {
            try container.encode(env, forKey: .env)
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

fileprivate struct DockControlSnapshot: Identifiable {
    let id: String
    let title: String
    let command: String
    let requestedHeight: Double?
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
            let resolvedControls = resolution.controls.map {
                DockControlRuntime(definition: $0, baseDirectory: resolution.baseDirectory, workspaceId: workspaceId)
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

    private let headerHeight: CGFloat = 30
    private let dividerHeight: CGFloat = 1
    private let minimumTerminalHeight: CGFloat = 160

    var body: some View {
        GeometryReader { proxy in
            let heights = terminalHeights(availableHeight: proxy.size.height)
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
                                .frame(height: dividerHeight)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .dockZeroScrollContentMargins()
        }
    }

    private func terminalHeights(availableHeight: CGFloat) -> [CGFloat] {
        guard !snapshots.isEmpty else { return [] }

        let chromeHeight = CGFloat(snapshots.count) * headerHeight
            + CGFloat(max(snapshots.count - 1, 0)) * dividerHeight
        let availableTerminalHeight = max(availableHeight - chromeHeight, 0)
        var heights = Array(repeating: CGFloat.zero, count: snapshots.count)
        var flexibleIndexes: [Int] = []
        var fixedHeightTotal: CGFloat = 0

        for (index, snapshot) in snapshots.enumerated() {
            if let requestedHeight = snapshot.requestedHeight {
                let fixedHeight = max(CGFloat(requestedHeight), minimumTerminalHeight)
                heights[index] = fixedHeight
                fixedHeightTotal += fixedHeight
            } else {
                flexibleIndexes.append(index)
            }
        }

        if flexibleIndexes.isEmpty {
            let extraHeight = max(availableTerminalHeight - fixedHeightTotal, 0)
            guard extraHeight > 0 else { return heights }
            let extraHeightPerControl = extraHeight / CGFloat(snapshots.count)
            return heights.map { $0 + extraHeightPerControl }
        }

        let remaining = max(availableTerminalHeight - fixedHeightTotal, 0)
        let sharedHeight = max(remaining / CGFloat(flexibleIndexes.count), minimumTerminalHeight)
        for index in flexibleIndexes {
            heights[index] = sharedHeight
        }

        return heights
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
