import AppKit
import Bonsplit
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
                debugDescription: "Dock control id must not be blank"
            )
        }
        guard !normalizedCommand.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .command,
                in: container,
                debugDescription: "Dock control command must not be blank"
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
final class DockControlRuntime: ObservableObject, Identifiable {
    let id: String
    let definition: DockControlDefinition
    let baseDirectory: String
    let paneId: PaneID
    @Published private(set) var panel: TerminalPanel

    init(definition: DockControlDefinition, baseDirectory: String) {
        self.id = definition.id
        self.definition = definition
        self.baseDirectory = baseDirectory
        self.paneId = PaneID(id: UUID())
        self.panel = Self.makePanel(definition: definition, baseDirectory: baseDirectory)
    }

    var terminalHeight: CGFloat {
        let requested = definition.height ?? 260
        return CGFloat(min(max(requested, 160), 700))
    }

    func focus() {
        panel.hostedView.ensureFocus(
            for: panel.surface.tabId,
            surfaceId: panel.id,
            respectForeignFirstResponder: false
        )
    }

    func restart() {
        let oldPanel = panel
        panel = Self.makePanel(definition: definition, baseDirectory: baseDirectory)
        oldPanel.close()
    }

    func close() {
        panel.close()
    }

    private static func makePanel(
        definition: DockControlDefinition,
        baseDirectory: String
    ) -> TerminalPanel {
        var template = CmuxSurfaceConfigTemplate()
        template.waitAfterCommand = true

        var environment = definition.env
        environment["CMUX_DOCK_CONTROL_ID"] = definition.id
        environment["CMUX_DOCK_CONTROL_TITLE"] = definition.title

        return TerminalPanel(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: template,
            workingDirectory: resolvedWorkingDirectory(definition.cwd, baseDirectory: baseDirectory),
            initialCommand: definition.command,
            initialEnvironmentOverrides: environment,
            focusPlacement: .rightSidebarDock
        )
    }

    private static func resolvedWorkingDirectory(_ cwd: String?, baseDirectory: String) -> String {
        guard let cwd, !cwd.isEmpty else { return baseDirectory }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseDirectory as NSString).appendingPathComponent(cwd)
    }
}

@MainActor
final class DockControlsStore: ObservableObject {
    @Published private(set) var controls: [DockControlRuntime] = []
    @Published private(set) var sourceLabel = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var trustRequest: DockTrustRequest?

    private var lastRootDirectory: String?

    func reload(rootDirectory: String?) {
        lastRootDirectory = rootDirectory
        errorMessage = nil
        trustRequest = nil

        do {
            let resolution = try Self.resolve(rootDirectory: rootDirectory)
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
                DockControlRuntime(definition: $0, baseDirectory: resolution.baseDirectory)
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
        reload(rootDirectory: lastRootDirectory)
    }

    func focusFirstControl() -> Bool {
        guard let first = controls.first else { return false }
        first.focus()
        return true
    }

    func openConfiguration() {
        do {
            let target = try Self.preferredEditableConfigURL(rootDirectory: lastRootDirectory)
            if !FileManager.default.fileExists(atPath: target.path) {
                try Self.writeTemplate(to: target)
            }
            NSWorkspace.shared.open(target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replaceControls(with newControls: [DockControlRuntime]) {
        let oldControls = controls
        controls = newControls
        oldControls.forEach { $0.close() }
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
            controls: [defaultFeedControl()],
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

    private static func defaultFeedControl() -> DockControlDefinition {
        DockControlDefinition(
            id: "feed",
            title: String(localized: "dock.default.feed.title", defaultValue: "Feed"),
            command: "cmux feed tui",
            height: 320
        )
    }

    private static func sourceLabel(for resolution: DockConfigResolution) -> String {
        if resolution.sourceURL == nil {
            return String(localized: "dock.source.builtIn", defaultValue: "Built-in Dock")
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
        FileManager.default.homeDirectoryForCurrentUser
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
            defaultFeedControl(),
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
    @StateObject private var store = DockControlsStore()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear {
            store.reload(rootDirectory: rootDirectory)
        }
        .onChange(of: rootDirectory) { newValue in
            store.reload(rootDirectory: newValue)
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
                store.reload(rootDirectory: rootDirectory)
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
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(store.controls.enumerated()), id: \.element.id) { index, runtime in
                        DockControlSectionView(
                            runtime: runtime,
                            ordinal: index + 1
                        )
                        if index < store.controls.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .dockZeroScrollContentMargins()
        }
    }
}

private struct DockControlSectionView: View {
    @ObservedObject var runtime: DockControlRuntime
    let ordinal: Int

    var body: some View {
        VStack(spacing: 0) {
            header
            DockTerminalView(runtime: runtime)
                .frame(height: runtime.terminalHeight)
                .clipped()
        }
        .accessibilityIdentifier("DockControl.\(runtime.id)")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(ordinal)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
            Text(runtime.definition.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(runtime.definition.command)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                runtime.focus()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "dock.action.focusControl", defaultValue: "Focus Control"))
            .accessibilityLabel(String(localized: "dock.action.focusControl", defaultValue: "Focus Control"))

            Button {
                runtime.restart()
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
        .background(Color.primary.opacity(0.035))
    }
}

private struct DockTerminalView: View {
    @ObservedObject var runtime: DockControlRuntime

    var body: some View {
        GhosttyTerminalView(
            terminalSurface: runtime.panel.surface,
            paneId: runtime.paneId,
            isActive: true,
            isVisibleInUI: true,
            portalZPriority: 1,
            searchState: runtime.panel.searchState,
            reattachToken: runtime.panel.viewReattachToken,
            onFocus: { _ in
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(
                    mode: .feed,
                    in: runtime.panel.hostedView.window
                )
            },
            onTriggerFlash: {
                runtime.panel.triggerFlash(reason: .debug)
            }
        )
        .id(runtime.panel.id)
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

private struct DockEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(String(localized: "dock.empty.title", defaultValue: "No Dock Controls"))
                .font(.system(size: 13, weight: .semibold))
            Text(String(
                localized: "dock.empty.subtitle",
                defaultValue: "Add controls to .cmux/dock.json."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
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
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class DockKeyboardFocusView: NSView {
    var focusFirstControl: (() -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerDockHost(self)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let surfaceId = ghosttyView.terminalSurface?.id else {
            return false
        }
        return TerminalSurfaceRegistry.shared.isRightSidebarDockSurface(id: surfaceId)
    }

    func focusFirstItemFromCoordinator() {
        _ = focusFirstControl?()
    }

    func focusHostFromCoordinator() -> Bool {
        if focusFirstControl?() == true {
            return true
        }
        return window?.makeFirstResponder(self) == true
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
