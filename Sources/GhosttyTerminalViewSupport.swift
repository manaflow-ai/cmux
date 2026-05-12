import AppKit
import Darwin
import QuartzCore

final class GhosttyPassthroughVisualEffectView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct TerminalStatusBarConfiguration: Equatable, Sendable {
    var enabled: Bool
    var heightRows: Int
    var command: String
    var refreshInterval: Double

    static let disabled = TerminalStatusBarConfiguration(
        enabled: false,
        heightRows: TerminalStatusBarSettings.defaultHeightRows,
        command: TerminalStatusBarSettings.defaultCommand,
        refreshInterval: TerminalStatusBarSettings.defaultRefreshInterval
    )

    var isRenderable: Bool {
        enabled && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func current(defaults: UserDefaults = .standard) -> TerminalStatusBarConfiguration {
        let rawHeightRows: Int
        if defaults.object(forKey: TerminalStatusBarSettings.heightRowsKey) != nil {
            rawHeightRows = defaults.integer(forKey: TerminalStatusBarSettings.heightRowsKey)
        } else {
            rawHeightRows = TerminalStatusBarSettings.defaultHeightRows
        }

        let rawRefreshInterval: Double
        if defaults.object(forKey: TerminalStatusBarSettings.refreshIntervalKey) != nil {
            rawRefreshInterval = defaults.double(forKey: TerminalStatusBarSettings.refreshIntervalKey)
        } else {
            rawRefreshInterval = TerminalStatusBarSettings.defaultRefreshInterval
        }

        return TerminalStatusBarConfiguration(
            enabled: defaults.object(forKey: TerminalStatusBarSettings.enabledKey) as? Bool
                ?? TerminalStatusBarSettings.defaultEnabled,
            heightRows: TerminalStatusBarSettings.normalizedHeightRows(rawHeightRows),
            command: defaults.string(forKey: TerminalStatusBarSettings.commandKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? TerminalStatusBarSettings.defaultCommand,
            refreshInterval: TerminalStatusBarSettings.normalizedRefreshInterval(rawRefreshInterval)
        )
    }
}

struct TerminalStatusBarExecutionContext: Sendable {
    let workspaceId: UUID
    let surfaceId: UUID
    let workingDirectory: String
}

enum TerminalStatusBarLayout {
    struct Frames: Equatable {
        let terminalFrame: CGRect
        let statusBarFrame: CGRect
        let reservedHeight: CGFloat
    }

    static func frames(
        in bounds: CGRect,
        rowCount: Int,
        cellHeight: CGFloat,
        isVisible: Bool
    ) -> Frames {
        guard isVisible, bounds.width > 0, bounds.height > 0 else {
            return Frames(terminalFrame: bounds, statusBarFrame: .zero, reservedHeight: 0)
        }

        let normalizedRows = TerminalStatusBarSettings.normalizedHeightRows(rowCount)
        let resolvedCellHeight = cellHeight > 0 ? cellHeight : 18
        let requestedHeight = CGFloat(normalizedRows) * resolvedCellHeight
        let reservedHeight = min(max(0, requestedHeight), max(0, bounds.height - resolvedCellHeight))
        guard reservedHeight > 0 else {
            return Frames(terminalFrame: bounds, statusBarFrame: .zero, reservedHeight: 0)
        }

        let statusBarFrame = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: reservedHeight
        )
        let terminalFrame = CGRect(
            x: bounds.minX,
            y: bounds.minY + reservedHeight,
            width: bounds.width,
            height: max(0, bounds.height - reservedHeight)
        )
        return Frames(
            terminalFrame: terminalFrame,
            statusBarFrame: statusBarFrame,
            reservedHeight: reservedHeight
        )
    }
}

final class TerminalStatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let borderLayer = CALayer()
    private var rowCount = TerminalStatusBarSettings.defaultHeightRows
    private var cellHeight: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        updateResolvedColors()

        layer?.addSublayer(borderLayer)

        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = TerminalStatusBarSettings.defaultHeightRows
        addSubview(label)

        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "terminal.statusBar.accessibilityLabel", defaultValue: "Terminal Status Bar"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateResolvedColors()
    }

    override func layout() {
        super.layout()
        borderLayer.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let horizontalInset: CGFloat = 8
        let verticalInset = max(1, floor((cellHeight - label.font!.pointSize) / 2))
        label.frame = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
    }

    func configure(configuration: TerminalStatusBarConfiguration, visible: Bool, cellHeight: CGFloat) {
        rowCount = configuration.heightRows
        self.cellHeight = cellHeight > 0 ? cellHeight : 18
        label.maximumNumberOfLines = rowCount
        label.font = .monospacedSystemFont(
            ofSize: max(10, min(13, self.cellHeight - 4)),
            weight: .regular
        )
        isHidden = !visible
        needsLayout = true
    }

    func setStatusText(_ text: String, rowCount: Int) {
        let normalized = Self.normalizedText(text, rowCount: rowCount)
        guard label.stringValue != normalized else { return }
        label.stringValue = normalized
        setAccessibilityValue(normalized)
    }

    private func updateResolvedColors() {
        layer?.backgroundColor = resolvedCGColor(.windowBackgroundColor, alpha: 0.92)
        borderLayer.backgroundColor = resolvedCGColor(.separatorColor, alpha: 0.55)
        label.textColor = .secondaryLabelColor
    }

    private func resolvedCGColor(_ color: NSColor, alpha: CGFloat) -> CGColor {
        color.resolvedColor(with: effectiveAppearance)
            .withAlphaComponent(alpha)
            .cgColor
    }

    private static func normalizedText(_ text: String, rowCount: Int) -> String {
        let normalizedRows = TerminalStatusBarSettings.normalizedHeightRows(rowCount)
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines)
        let lines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(normalizedRows)
            .map(String.init)
        return lines.joined(separator: "\n")
    }
}

private final class TerminalStatusBarProcessWaitState: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var didTimeout = false
    private var didResume = false

    init(process: Process) {
        self.process = process
    }

    func markTimedOut() {
        lock.lock()
        didTimeout = true
        lock.unlock()
    }

    func finish() -> (shouldResume: Bool, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else {
            return (false, didTimeout)
        }
        didResume = true
        return (true, didTimeout)
    }
}

final class TerminalStatusBarCommandController {
    private struct AppliedState: Equatable {
        let configuration: TerminalStatusBarConfiguration
        let active: Bool
    }

    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var appliedState: AppliedState?
    private var isCommandRunning = false
    private var contextProvider: (@MainActor () -> TerminalStatusBarExecutionContext?)?
    private var outputHandler: (@MainActor (String, Int) -> Void)?

    @MainActor
    func apply(
        configuration: TerminalStatusBarConfiguration,
        active: Bool,
        contextProvider: @escaping @MainActor () -> TerminalStatusBarExecutionContext?,
        outputHandler: @escaping @MainActor (String, Int) -> Void
    ) {
        let nextState = AppliedState(configuration: configuration, active: active)
        guard appliedState != nextState else { return }
        stop()
        appliedState = nextState

        guard active, configuration.isRenderable else {
            outputHandler("", configuration.heightRows)
            return
        }

        self.contextProvider = contextProvider
        self.outputHandler = outputHandler
        let currentGeneration = generation
        runCommand(configuration: configuration, generation: currentGeneration)
        scheduleTimer(configuration: configuration, generation: currentGeneration)
    }

    func stop() {
        generation &+= 1
        appliedState = nil
        contextProvider = nil
        outputHandler = nil
        isCommandRunning = false
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    @MainActor
    private func scheduleTimer(configuration: TerminalStatusBarConfiguration, generation: UInt64) {
        let timer = Timer(timeInterval: configuration.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runCommand(configuration: configuration, generation: generation)
            }
        }
        timer.tolerance = min(0.5, max(0.01, configuration.refreshInterval * 0.1))
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @MainActor
    private func runCommand(configuration: TerminalStatusBarConfiguration, generation: UInt64) {
        guard self.generation == generation else { return }
        guard !isCommandRunning else { return }
        guard let context = contextProvider?() else { return }
        isCommandRunning = true
        task = Task { @MainActor [weak self] in
            let output = await Self.runStatusCommand(
                configuration.command,
                context: context,
                timeout: min(5, max(1, configuration.refreshInterval))
            )
            guard let self else { return }
            guard self.generation == generation else { return }
            self.isCommandRunning = false
            self.task = nil
            self.outputHandler?(output, configuration.heightRows)
        }
    }

    private nonisolated static func runStatusCommand(
        _ command: String,
        context: TerminalStatusBarExecutionContext,
        timeout: TimeInterval
    ) async -> String {
        let process = Process()
        let shell = resolvedShell()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-status-\(UUID().uuidString).txt", isDirectory: false)

        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            return ""
        }
        defer {
            outputHandle.closeFile()
            try? FileManager.default.removeItem(at: outputURL)
        }

        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shellArguments(for: shell, command: command)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        process.environment = environment(for: context)
        process.currentDirectoryURL = validatedDirectory(context.workingDirectory)

        _ = await runAndWaitForTermination(process: process, timeout: timeout)
        outputHandle.synchronizeFile()
        guard let readHandle = try? FileHandle(forReadingFrom: outputURL) else {
            return ""
        }
        defer { readHandle.closeFile() }
        let data = readHandle.readData(ofLength: 8192)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private nonisolated static func runAndWaitForTermination(
        process: Process,
        timeout: TimeInterval
    ) async -> Bool {
        let state = TerminalStatusBarProcessWaitState(process: process)

        return await withCheckedContinuation { continuation in
            let timeoutSource = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            process.terminationHandler = { _ in
                timeoutSource.cancel()
                let result = state.finish()
                if result.shouldResume {
                    continuation.resume(returning: result.timedOut)
                }
            }
            timeoutSource.setEventHandler {
                state.markTimedOut()
                state.process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    if state.process.isRunning {
                        kill(state.process.processIdentifier, SIGKILL)
                    }
                }
            }
            timeoutSource.schedule(deadline: .now() + timeout)
            timeoutSource.resume()

            do {
                try process.run()
            } catch {
                timeoutSource.cancel()
                process.terminationHandler = nil
                let result = state.finish()
                if result.shouldResume {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private nonisolated static func resolvedShell() -> String {
        let environmentShell = ProcessInfo.processInfo.environment["SHELL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentShell, !environmentShell.isEmpty,
           FileManager.default.isExecutableFile(atPath: environmentShell) {
            return environmentShell
        }
        return "/bin/sh"
    }

    private nonisolated static func shellArguments(for shell: String, command: String) -> [String] {
        if (shell as NSString).lastPathComponent == "fish" {
            return ["-l", "-c", command]
        }
        return ["-lc", command]
    }

    private nonisolated static func validatedDirectory(_ path: String) -> URL {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private nonisolated static func environment(for context: TerminalStatusBarExecutionContext) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_WORKSPACE_ID"] = context.workspaceId.uuidString
        environment["CMUX_SURFACE_ID"] = context.surfaceId.uuidString
        environment["PWD"] = context.workingDirectory
        return environment
    }
}

func shouldAllowEnsureFocusWindowActivation(
    activeTabManager: TabManager?,
    targetTabManager: TabManager,
    keyWindow: NSWindow?,
    mainWindow: NSWindow?,
    targetWindow: NSWindow
) -> Bool {
    guard activeTabManager === targetTabManager || (keyWindow == nil && mainWindow == nil) else {
        return false
    }

    if let keyWindow {
        return keyWindow === targetWindow
    }

    if let mainWindow {
        return mainWindow === targetWindow
    }

    return true
}

extension TerminalSurface {
    func debugInitialCommand() -> String? {
        initialCommand
    }

    func debugTmuxStartCommand() -> String? {
        tmuxStartCommand
    }

    func debugInitialInputMetadata() -> (hasInitialInput: Bool, byteCount: Int) {
        let byteCount = initialInput?.utf8.count ?? 0
        return (byteCount > 0, byteCount)
    }
}
