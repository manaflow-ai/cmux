import AppKit
import Foundation
import SwiftUI

extension ContentView {
    static func commandPaletteViewCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel")),
                subtitle: constant(String(localized: "command.triggerFlash.subtitle", defaultValue: "View")),
                keywords: ["flash", "highlight", "focus", "panel"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.openTaskManager",
                title: constant(String(localized: "taskManager.title", defaultValue: "Task Manager")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["task", "manager", "process", "cpu", "memory", "kill"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.attachTmuxSession",
                title: constant(String(localized: "command.attachTmuxSession.title", defaultValue: "Attach tmux Session…")),
                subtitle: constant(String(localized: "command.attachTmuxSession.subtitle", defaultValue: "Terminal")),
                keywords: ["tmux", "attach", "session", "ssh", "remote", "terminal"]
            ),
        ]
    }

    func registerViewCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.openTaskManager") {
            TaskManagerWindowController.shared.show()
        }
        registry.register(commandId: "palette.attachTmuxSession") {
            Task { @MainActor in
                TmuxAttachWindowController.shared.show(tabManager: tabManager)
            }
        }
    }
}

enum TmuxAttachConnectionMode: String, CaseIterable, Identifiable, Sendable {
    case local
    case ssh

    var id: String { rawValue }
}

struct TmuxAttachSession: Identifiable, Equatable, Sendable {
    let name: String
    let windowCount: Int
    let attachedClientCount: Int

    var id: String { name }
    var isAttached: Bool { attachedClientCount > 0 }
}

struct TmuxAttachRequest: Equatable, Sendable {
    var mode: TmuxAttachConnectionMode
    var sshTarget: String
    var sessionName: String
    var createIfMissing: Bool
}

enum TmuxAttachCommandBuilder {
    enum BuilderError: LocalizedError, Equatable, Sendable {
        case missingSSHTarget
        case startupScriptWriteFailed(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingSSHTarget:
                return String(localized: "tmuxAttach.error.sshTargetRequired", defaultValue: "Enter an SSH target.")
            case .startupScriptWriteFailed(let message):
                let format = String(
                    localized: "tmuxAttach.error.scriptFailed",
                    defaultValue: "Could not create tmux attach command: %@"
                )
                return String(format: format, message)
            case .commandFailed(let message):
                let format = String(
                    localized: "tmuxAttach.error.commandFailed",
                    defaultValue: "Command failed: %@"
                )
                return String(format: format, message)
            }
        }
    }

    static let defaultCreatedSessionName = "cmux"
    static let tmuxSearchPathPrefix = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func normalizedSessionName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedSSHTarget(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func tmuxCommand(for request: TmuxAttachRequest, includeSearchPath: Bool = false) -> String {
        let tmuxExecutable = includeSearchPath
            ? "/usr/bin/env PATH=\(tmuxSearchPathPrefix):${PATH:-} tmux"
            : "tmux"
        if request.createIfMissing {
            let session = normalizedSessionName(request.sessionName) ?? defaultCreatedSessionName
            return "\(tmuxExecutable) new-session -A -s \(shellQuote(session))"
        }

        guard let session = normalizedSessionName(request.sessionName) else {
            return "\(tmuxExecutable) attach-session"
        }
        return "\(tmuxExecutable) attach-session -t \(shellQuote(session))"
    }

    static func startupCommandLine(for request: TmuxAttachRequest) throws -> String {
        let tmuxCommand = tmuxCommand(for: request, includeSearchPath: true)
        switch request.mode {
        case .local:
            return "exec \(tmuxCommand)"
        case .ssh:
            guard let target = normalizedSSHTarget(request.sshTarget) else {
                throw BuilderError.missingSSHTarget
            }
            return "exec /usr/bin/ssh -tt -- \(shellQuote(target)) \(shellQuote(tmuxCommand))"
        }
    }

    static func workspaceTitle(for request: TmuxAttachRequest) -> String {
        let session = normalizedSessionName(request.sessionName)
            ?? (request.createIfMissing ? defaultCreatedSessionName : "tmux")
        switch request.mode {
        case .local:
            return "tmux: \(session)"
        case .ssh:
            let target = normalizedSSHTarget(request.sshTarget) ?? "ssh"
            return "tmux: \(target)/\(session)"
        }
    }

    static func makeStartupScript(for request: TmuxAttachRequest) throws -> String {
        let commandLine = try startupCommandLine(for: request)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-attach-\(UUID().uuidString.lowercased()).sh")

        var lines = [
            "#!/bin/sh",
            "rm -f -- \"$0\" 2>/dev/null || true"
        ]

        if request.mode == .local {
            let missingTmux = String(
                localized: "tmuxAttach.error.tmuxMissing",
                defaultValue: "tmux is not installed or is not in PATH."
            )
            lines.append(
                "if ! PATH=\(tmuxSearchPathPrefix):${PATH:-} command -v tmux >/dev/null 2>&1; then printf '%s\\n' \(shellQuote(missingTmux)) >&2; exit 127; fi"
            )
        }

        lines.append(commandLine)

        do {
            try (lines.joined(separator: "\n") + "\n").write(
                to: scriptURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            return scriptURL.path
        } catch {
            throw BuilderError.startupScriptWriteFailed(error.localizedDescription)
        }
    }

    static func listSessions(mode: TmuxAttachConnectionMode, sshTarget: String) async throws -> [TmuxAttachSession] {
        try await Task.detached(priority: .userInitiated) {
            let format = "#S\t#{session_windows}\t#{session_attached}"
            let result: CommandResult
            switch mode {
            case .local:
                result = try Self.runCommand(
                    executable: "/usr/bin/env",
                    arguments: ["tmux", "list-sessions", "-F", format]
                )
            case .ssh:
                guard let target = Self.normalizedSSHTarget(sshTarget) else {
                    throw BuilderError.missingSSHTarget
                }
                let remoteCommand = "PATH=\(Self.tmuxSearchPathPrefix):${PATH:-} tmux list-sessions -F \(Self.shellQuote(format))"
                result = try Self.runCommand(
                    executable: "/usr/bin/ssh",
                    arguments: [
                        "-o", "BatchMode=yes",
                        "-o", "ConnectTimeout=5",
                        "--",
                        target,
                        remoteCommand
                    ]
                )
            }

            if result.status != 0 {
                let message = [result.stderr, result.stdout]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lowered = message.lowercased()
                if lowered.contains("no server running") || lowered.contains("failed to connect to server") {
                    return []
                }
                throw BuilderError.commandFailed(message.isEmpty ? "exit \(result.status)" : message)
            }

            return Self.parseSessionList(result.stdout)
        }.value
    }

    static func parseSessionList(_ output: String) -> [TmuxAttachSession] {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> TmuxAttachSession? in
                let line = String(rawLine).trimmingCharacters(in: .newlines)
                guard !line.isEmpty else { return nil }
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard let name = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else {
                    return nil
                }
                let windows = fields.dropFirst().first.flatMap { Int($0) } ?? 0
                let attached = fields.dropFirst(2).first.flatMap { Int($0) } ?? 0
                return TmuxAttachSession(
                    name: name,
                    windowCount: max(0, windows),
                    attachedClientCount: max(0, attached)
                )
            }
    }

    private struct CommandResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runCommand(executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [tmuxSearchPathPrefix, environment["PATH"]]
            .compactMap { $0 }
            .joined(separator: ":")
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

@MainActor
private final class TmuxAttachViewModel: ObservableObject {
    @Published var mode: TmuxAttachConnectionMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.lastModeKey)
            sessions = []
            selectedSessionName = nil
            errorMessage = nil
        }
    }
    @Published var sshTarget: String {
        didSet {
            UserDefaults.standard.set(sshTarget, forKey: Self.lastSSHTargetKey)
        }
    }
    @Published var sessionName: String {
        didSet {
            UserDefaults.standard.set(sessionName, forKey: Self.lastSessionNameKey)
        }
    }
    @Published var createIfMissing: Bool {
        didSet {
            UserDefaults.standard.set(createIfMissing, forKey: Self.createIfMissingKey)
        }
    }
    @Published private(set) var sessions: [TmuxAttachSession] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedSessionName: String? {
        didSet {
            if let selectedSessionName {
                sessionName = selectedSessionName
            }
        }
    }

    var onClose: (() -> Void)?

    private weak var tabManager: TabManager?
    private var refreshGeneration = 0

    private static let lastModeKey = "tmuxAttach.lastMode"
    private static let lastSSHTargetKey = "tmuxAttach.lastSSHTarget"
    private static let lastSessionNameKey = "tmuxAttach.lastSessionName"
    private static let createIfMissingKey = "tmuxAttach.createIfMissing"

    init() {
        let defaults = UserDefaults.standard
        let rawMode = defaults.string(forKey: Self.lastModeKey) ?? TmuxAttachConnectionMode.local.rawValue
        mode = TmuxAttachConnectionMode(rawValue: rawMode) ?? .local
        sshTarget = defaults.string(forKey: Self.lastSSHTargetKey) ?? ""
        sessionName = defaults.string(forKey: Self.lastSessionNameKey) ?? ""
        if defaults.object(forKey: Self.createIfMissingKey) == nil {
            createIfMissing = true
        } else {
            createIfMissing = defaults.bool(forKey: Self.createIfMissingKey)
        }
    }

    var canRefresh: Bool {
        mode == .local || TmuxAttachCommandBuilder.normalizedSSHTarget(sshTarget) != nil
    }

    var canConnect: Bool {
        canRefresh
    }

    func configure(tabManager: TabManager) {
        self.tabManager = tabManager
        errorMessage = nil
    }

    func refreshSessions() {
        guard canRefresh else {
            errorMessage = String(localized: "tmuxAttach.error.sshTargetRequired", defaultValue: "Enter an SSH target.")
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let mode = self.mode
        let sshTarget = self.sshTarget
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let loaded = try await TmuxAttachCommandBuilder.listSessions(
                    mode: mode,
                    sshTarget: sshTarget
                )
                guard generation == refreshGeneration else { return }
                sessions = loaded
                if let selectedSessionName,
                   loaded.contains(where: { $0.name == selectedSessionName }) {
                    sessionName = selectedSessionName
                } else if let first = loaded.first, sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedSessionName = first.name
                    sessionName = first.name
                }
                isLoading = false
            } catch {
                guard generation == refreshGeneration else { return }
                sessions = []
                selectedSessionName = nil
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isLoading = false
            }
        }
    }

    func selectSession(_ session: TmuxAttachSession) {
        selectedSessionName = session.name
    }

    func connect() {
        guard let tabManager else {
            errorMessage = String(localized: "tmuxAttach.error.noTabManager", defaultValue: "No active cmux window.")
            NSSound.beep()
            return
        }

        let request = TmuxAttachRequest(
            mode: mode,
            sshTarget: sshTarget,
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )

        do {
            let scriptPath = try TmuxAttachCommandBuilder.makeStartupScript(for: request)
            tabManager.addWorkspace(
                title: TmuxAttachCommandBuilder.workspaceTitle(for: request),
                initialTerminalCommand: scriptPath,
                inheritWorkingDirectory: false,
                select: true,
                eagerLoadTerminal: true
            )
            onClose?()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSSound.beep()
        }
    }
}

@MainActor
private final class TmuxAttachWindowController: NSWindowController {
    static let shared = TmuxAttachWindowController()

    private let model: TmuxAttachViewModel

    private init() {
        let model = TmuxAttachViewModel()
        self.model = model
        let hostingController = NSHostingController(rootView: TmuxAttachView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "tmuxAttach.window.title", defaultValue: "Attach tmux Session")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 380))
        window.minSize = NSSize(width: 420, height: 340)
        super.init(window: window)
        model.onClose = { [weak self] in
            self?.window?.close()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    func show(tabManager: TabManager) {
        model.configure(tabManager: tabManager)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refreshSessions()
    }
}

private struct TmuxAttachView: View {
    @ObservedObject var model: TmuxAttachViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            modePicker
            connectionFields
            sessionPicker
            Toggle(isOn: $model.createIfMissing) {
                Text(String(localized: "tmuxAttach.createIfMissing", defaultValue: "Create if missing"))
            }
            .toggleStyle(.checkbox)
            statusArea
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
            Text(String(localized: "tmuxAttach.window.title", defaultValue: "Attach tmux Session"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                model.refreshSessions()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!model.canRefresh || model.isLoading)
            .help(String(localized: "tmuxAttach.button.refresh", defaultValue: "Refresh"))
        }
    }

    private var modePicker: some View {
        Picker("", selection: $model.mode) {
            Text(String(localized: "tmuxAttach.mode.local", defaultValue: "Local"))
                .tag(TmuxAttachConnectionMode.local)
            Text(String(localized: "tmuxAttach.mode.ssh", defaultValue: "SSH"))
                .tag(TmuxAttachConnectionMode.ssh)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var connectionFields: some View {
        if model.mode == .ssh {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "tmuxAttach.field.sshTarget", defaultValue: "SSH Target"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(
                    String(localized: "tmuxAttach.field.sshTarget.placeholder", defaultValue: "user@host"),
                    text: $model.sshTarget
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "tmuxAttach.field.session", defaultValue: "Session"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            TextField(
                String(localized: "tmuxAttach.field.session.placeholder", defaultValue: "cmux"),
                text: $model.sessionName
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "tmuxAttach.sessions.heading", defaultValue: "Sessions"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "tmuxAttach.status.loading", defaultValue: "Loading sessions…"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else if model.sessions.isEmpty {
                Text(String(localized: "tmuxAttach.status.noSessions", defaultValue: "No sessions found"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.sessions) { session in
                            TmuxAttachSessionRow(
                                session: session,
                                isSelected: model.selectedSessionName == session.name,
                                onSelect: { model.selectSession(session) }
                            )
                        }
                    }
                }
                .frame(minHeight: 92, maxHeight: 120)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "tmuxAttach.button.cancel", defaultValue: "Cancel")) {
                model.onClose?()
            }
            Button(String(localized: "tmuxAttach.button.connect", defaultValue: "Connect")) {
                model.connect()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canConnect)
        }
    }
}

private struct TmuxAttachSessionRow: View, Equatable {
    let session: TmuxAttachSession
    let isSelected: Bool
    let onSelect: () -> Void

    static func == (lhs: TmuxAttachSessionRow, rhs: TmuxAttachSessionRow) -> Bool {
        lhs.session == rhs.session && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text(verbatim: session.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10, weight: .medium))
                    Text(verbatim: "\(session.windowCount)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundColor(.secondary)
                Text(
                    session.isAttached
                        ? String(localized: "tmuxAttach.status.attached", defaultValue: "Attached")
                        : String(localized: "tmuxAttach.status.detached", defaultValue: "Detached")
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(session.isAttached ? .accentColor : .secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
    }
}
