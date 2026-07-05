import AppKit
import CmuxFoundation
import CmuxSettings
import Bonsplit
import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let defaultTerminalRegistrationDidChange = Notification.Name("DefaultTerminalRegistration.didChange")
}

struct DefaultTerminalRegistrationStatus: Equatable {
    let matchedTargetCount: Int
    let targetCount: Int

    var isDefault: Bool {
        matchedTargetCount == targetCount
    }
}

enum DefaultTerminalRegistrationError: Error, LocalizedError {
    case launchServicesRegistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .launchServicesRegistrationFailed:
            return String(
                localized: "error.defaultTerminal.registrationFailed",
                defaultValue: "cmux could not register as the default terminal app."
            )
        }
    }
}

enum DefaultTerminalRegistration {
    static let urlSchemes = ["ssh"]
    static let contentTypeIdentifiers = [
        "com.apple.terminal.shell-script",
        "public.unix-executable"
    ]

    static func contentType(forIdentifier identifier: String) -> UTType {
        UTType(identifier) ?? UTType(importedAs: identifier)
    }

    static var targetCount: Int {
        urlSchemes.count + contentTypeIdentifiers.count
    }

    static func currentStatus(
        bundleURL: URL = Bundle.main.bundleURL,
        workspace: NSWorkspace = .shared
    ) -> DefaultTerminalRegistrationStatus {
        let normalizedBundleURL = normalizedApplicationURL(bundleURL)
        let matchedURLSchemes = urlSchemes.filter { scheme in
            guard let url = URL(string: "\(scheme)://cmux-default-terminal-check") else {
                return false
            }
            return normalizedApplicationURL(workspace.urlForApplication(toOpen: url)) == normalizedBundleURL
        }.count

        let matchedContentTypes = contentTypeIdentifiers.filter { identifier in
            let contentType = contentType(forIdentifier: identifier)
            return normalizedApplicationURL(workspace.urlForApplication(toOpen: contentType)) == normalizedBundleURL
        }.count

        return DefaultTerminalRegistrationStatus(
            matchedTargetCount: matchedURLSchemes + matchedContentTypes,
            targetCount: targetCount
        )
    }

    static func setAsDefault(bundleURL: URL = Bundle.main.bundleURL) async throws {
        let normalizedBundleURL = normalizedApplicationURL(bundleURL) ?? bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        var didAttemptHandlerUpdate = false
        defer {
            if didAttemptHandlerUpdate {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .defaultTerminalRegistrationDidChange, object: nil)
                }
            }
        }

        let registerStatus = LSRegisterURL(normalizedBundleURL as CFURL, true)
        guard registerStatus == noErr else {
            throw DefaultTerminalRegistrationError.launchServicesRegistrationFailed(registerStatus)
        }
        didAttemptHandlerUpdate = true

        for scheme in urlSchemes {
            try await NSWorkspace.shared.setDefaultApplication(
                at: normalizedBundleURL,
                toOpenURLsWithScheme: scheme
            )
        }

        for identifier in contentTypeIdentifiers {
            let contentType = contentType(forIdentifier: identifier)
            try await NSWorkspace.shared.setDefaultApplication(
                at: normalizedBundleURL,
                toOpen: contentType
            )
        }
    }

    private static func normalizedApplicationURL(_ url: URL?) -> URL? {
        url?.standardizedFileURL.resolvingSymlinksInPath()
    }
}

@MainActor
enum DefaultTerminalUserAction {
    private struct RegistrationOperation {
        let id: UUID
        let task: Task<Void, Error>
    }

    private static var inFlightRegistration: RegistrationOperation?

    @discardableResult
    static func registerAsDefault() async throws -> Bool {
        if let operation = inFlightRegistration {
            do {
                try await operation.task.value
            } catch {
                return false
            }
            return false
        }

        let operation = RegistrationOperation(
            id: UUID(),
            task: Task {
                try await DefaultTerminalRegistration.setAsDefault()
            }
        )
        inFlightRegistration = operation

        do {
            try await operation.task.value
            if inFlightRegistration?.id == operation.id {
                inFlightRegistration = nil
            }
            return true
        } catch {
            if inFlightRegistration?.id == operation.id {
                inFlightRegistration = nil
            }
            throw error
        }
    }

    static func setAsDefault(debugSource: String) {
#if DEBUG
        cmuxDebugLog("defaultTerminal.setAsDefault source=\(debugSource)")
#endif
        Task {
            do {
                try await registerAsDefault()
            } catch {
#if DEBUG
                cmuxDebugLog("defaultTerminal.setAsDefault.failed source=\(debugSource) error=\(error)")
#endif
                presentSetAsDefaultError(error)
            }
        }
    }

    private static func presentSetAsDefaultError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.defaultTerminal.setFailed.title",
            defaultValue: "Could Not Set Default Terminal"
        )
        alert.informativeText = (error as? DefaultTerminalRegistrationError)?.errorDescription ?? String(
            localized: "defaultTerminal.updateFailed.message",
            defaultValue: "macOS could not update every default terminal handler."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.window.identifier = NSUserInterfaceItemIdentifier("cmux.defaultTerminalRegistrationError")
        alert.runModal()
    }
}

struct TerminalDefaultFileOpenRequest: Equatable {
    let fileURL: URL
    let workingDirectory: String
    let initialInput: String

    init?(fileURL: URL, contentType: UTType? = nil, isExecutable: Bool? = nil) {
        guard fileURL.isFileURL else { return nil }
        let standardizedURL = fileURL.standardizedFileURL
        let directoryCheckURL = standardizedURL.resolvingSymlinksInPath()
        guard !SessionPersistencePolicy.isCmuxCrashStorageURL(standardizedURL) else { return nil }
        guard !SessionPersistencePolicy.isCmuxCrashStorageURL(directoryCheckURL) else { return nil }
        let resourceValues = try? directoryCheckURL.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues?.isDirectory != true else { return nil }
        let resolvedContentType = contentType ?? Self.contentType(for: standardizedURL)
        let resolvedIsExecutable = isExecutable ?? Self.isExecutableFile(directoryCheckURL)
        guard Self.shouldRunInTerminal(
            fileURL: standardizedURL,
            contentType: resolvedContentType,
            isExecutable: resolvedIsExecutable
        ) else {
            return nil
        }

        self.fileURL = standardizedURL
        self.workingDirectory = standardizedURL.deletingLastPathComponent().path(percentEncoded: false)
        self.initialInput = "\(Self.shellSingleQuoted(standardizedURL.path(percentEncoded: false)))\n"
    }

    static func requests(from urls: [URL]) -> [TerminalDefaultFileOpenRequest] {
        var seen: Set<String> = []
        var requests: [TerminalDefaultFileOpenRequest] = []
        for url in urls {
            guard let request = TerminalDefaultFileOpenRequest(fileURL: url) else { continue }
            let path = request.fileURL.path(percentEncoded: false)
            guard seen.insert(path).inserted else { continue }
            requests.append(request)
        }
        return requests
    }

    private static func contentType(for fileURL: URL) -> UTType? {
        try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
    }

    private static func isExecutableFile(_ fileURL: URL) -> Bool {
        if (try? fileURL.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true {
            return true
        }
        return FileManager.default.isExecutableFile(atPath: fileURL.path(percentEncoded: false))
    }

    private static func shouldRunInTerminal(fileURL: URL, contentType: UTType?, isExecutable: Bool) -> Bool {
        if isTerminalShellScript(fileURL: fileURL, contentType: contentType) {
            return true
        }
        return contentType?.conforms(to: .unixExecutable) == true || isExecutable
    }

    private static func isTerminalShellScript(fileURL: URL, contentType: UTType?) -> Bool {
        if contentType?.identifier == "com.apple.terminal.shell-script" {
            return true
        }
        switch fileURL.pathExtension.lowercased() {
        case "command", "tool":
            return true
        default:
            return false
        }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
final class CmuxSSHURLProcessLauncher {
    static let shared = CmuxSSHURLProcessLauncher()

    private var processes: [Int32: Process] = [:]
    private var isShuttingDown = false

    private init() {}

    func terminateAll() {
        isShuttingDown = true
        for process in processes.values where process.isRunning {
            process.terminate()
        }
        processes.removeAll()
    }

    @discardableResult
    func start(request: CmuxSSHURLRequest, preferredWindow: NSWindow?) -> Bool {
        let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        guard let cliURL,
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            presentLaunchFailure(
                summary: String(
                    localized: "dialog.sshURL.launchFailed.missingCLI",
                    defaultValue: "The bundled cmux CLI is missing from this app build."
                ),
                output: "",
                preferredWindow: preferredWindow
            )
            return false
        }

        let socketPath = resolvedSocketPath()
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--socket", socketPath] + request.cliArguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputCollector = ProcessOutputCollector(stdout: outputPipe, stderr: errorPipe)
        outputCollector.start()
        process.terminationHandler = { [weak preferredWindow] terminatedProcess in
            let output = outputCollector.finish()
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                Self.shared.processes.removeValue(forKey: processIdentifier)
                guard terminationStatus != 0, !Self.shared.isShuttingDown else { return }
                let format = String(
                    localized: "dialog.sshURL.launchFailed.exit",
                    defaultValue: "cmux ssh exited with status %d."
                )
                Self.shared.presentLaunchFailure(
                    summary: String(format: format, Int(terminationStatus)),
                    output: output,
                    preferredWindow: preferredWindow
                )
            }
        }

        do {
            try process.run()
            processes[process.processIdentifier] = process
#if DEBUG
            cmuxDebugLog("sshURL.launchCLI pid=\(process.processIdentifier) socket=\(socketPath) targetLength=\(request.destination.count)")
#endif
            return true
        } catch {
            outputCollector.cancel()
            presentLaunchFailure(
                summary: String(
                    localized: "dialog.sshURL.launchFailed.launch",
                    defaultValue: "cmux ssh could not be launched."
                ),
                output: error.localizedDescription,
                preferredWindow: preferredWindow
            )
            return false
        }
    }

    func resolvedSocketPath() -> String {
        TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
    }

    private func presentLaunchFailure(summary: String, output: String, preferredWindow: NSWindow?) {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let limitedOutput = String(trimmedOutput.prefix(2000))
        let informativeText = limitedOutput.isEmpty
            ? summary
            : "\(summary)\n\n\(limitedOutput)"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.sshURL.launchFailed.title",
            defaultValue: "Couldn't Open SSH Link"
        )
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        if let preferredWindow {
            alert.beginSheetModal(for: preferredWindow, completionHandler: nil)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

@MainActor
private final class CmuxSSHURLConfirmationGate: NSObject {
    weak var connectButton: NSButton?

    @objc func checkboxChanged(_ sender: NSButton) {
        connectButton?.isEnabled = sender.state == .on
    }
}

extension AppDelegate {
    func deferInitialMainWindowBootstrapForExternalConfirmation() {
        guard !didAttemptStartupSessionRestore, !didHandleExplicitOpenIntentAtStartup else { return }
        shouldDeferInitialMainWindowBootstrapForExternalConfirmation = true
    }

    func resumeInitialMainWindowBootstrapAfterExternalConfirmation(debugSource: String) {
        guard shouldDeferInitialMainWindowBootstrapForExternalConfirmation else { return }
        shouldDeferInitialMainWindowBootstrapForExternalConfirmation = false
        scheduleInitialMainWindowBootstrap(debugSource: debugSource)
    }

    func bootstrapInitialMainWindowAfterAcceptedExternalOpen(
        debugSource: String,
        shouldActivate: Bool = true,
        suppressWelcome: Bool = false
    ) {
        shouldDeferInitialMainWindowBootstrapForExternalConfirmation = false
        _ = bootstrapInitialMainWindowIfNeeded(
            debugSource: debugSource,
            shouldActivate: shouldActivate,
            suppressWelcome: suppressWelcome
        )
    }

    func claimAuthCallbackURLSchemes() {
        // Pin the current build's callback scheme so auth, SSH, and navigation deeplinks
        // route back to this app instead of an unrelated LaunchServices entry.
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(
            at: bundleURL,
            toOpenURLsWithScheme: AuthEnvironment.callbackScheme
        ) { _ in }
    }

    @discardableResult
    func handleCmuxExternalURLs(from urls: [URL]) -> Bool {
        let intentCounts = cmuxExternalURLIntentCounts(in: urls)
        guard intentCounts.total > 0 else { return false }
        guard intentCounts.total == 1 else {
            if intentCounts.ssh > 1 && intentCounts.navigation == 0 && intentCounts.text == 0 {
                showCmuxSSHURLParseError(.multipleLinks)
            } else {
                showCmuxTextURLParseError(.multipleLinks)
            }
            return true
        }

        if handleCmuxSSHURLs(from: urls) {
            return true
        }
        if handleCmuxNavigationURLs(from: urls) {
            return true
        }
        if handleCmuxTextURLs(from: urls) {
            return true
        }
        if handleCmuxExtensionInstallURLs(from: urls) {
            return true
        }
        return false
    }

    private struct CmuxExternalURLIntentCounts {
        var ssh = 0
        var navigation = 0
        var text = 0
        var extensionInstall = 0

        var total: Int {
            ssh + navigation + text + extensionInstall
        }
    }

    private func cmuxExternalURLIntentCounts(in urls: [URL]) -> CmuxExternalURLIntentCounts {
        urls.reduce(CmuxExternalURLIntentCounts()) { counts, url in
            var nextCounts = counts
            switch CmuxSSHURLRequest.parse(url) {
            case .success(.some), .failure:
                nextCounts.ssh += 1
            case .success(nil):
                break
            }
            switch CmuxNavigationURLRequest.parse(url) {
            case .success(.some), .failure:
                nextCounts.navigation += 1
            case .success(nil):
                break
            }
            switch CmuxTextURLRequest.parse(url) {
            case .success(.some), .failure:
                nextCounts.text += 1
            case .success(nil):
                break
            }
            switch CmuxExtensionInstallURLRequest.parse(url) {
            case .success(.some), .failure:
                nextCounts.extensionInstall += 1
            case .success(nil):
                break
            }
            return nextCounts
        }
    }

    /// `cmux://extensions/install?repo=…` — opens the extension consent
    /// window; nothing installs without the user approving the previewed
    /// commands there (a deep link can never skip consent).
    @discardableResult
    func handleCmuxExtensionInstallURLs(from urls: [URL]) -> Bool {
        var requests: [CmuxExtensionInstallURLRequest] = []
        var parseErrorCount = 0

        for url in urls {
            switch CmuxExtensionInstallURLRequest.parse(url) {
            case .success(.some(let request)):
                requests.append(request)
            case .success(nil):
                break
            case .failure(let error):
#if DEBUG
                cmuxDebugLog("extensionInstallURL.blocked reason=\(error) url=\(url.absoluteString.prefix(160))")
#endif
                parseErrorCount += 1
            }
        }

        let intentCount = requests.count + parseErrorCount
        guard intentCount > 0 else { return false }
        guard intentCount == 1, let request = requests.first else {
            // Malformed or multiple install links: recognized, but never acted
            // on. The consent window is the only path to an install.
            return true
        }

        DockExtensionsRuntime.shared.installCoordinator.beginInstall(
            input: request.source,
            ref: request.ref
        )
        return true
    }

    @discardableResult
    func handleCmuxNavigationURLs(from urls: [URL]) -> Bool {
        var navigationRequests: [CmuxNavigationURLRequest] = []
        var parseErrors: [(url: URL, error: CmuxNavigationURLParseError)] = []

        for url in urls {
            switch CmuxNavigationURLRequest.parse(url) {
            case .success(.some(let request)):
                navigationRequests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                parseErrors.append((url, error))
            }
        }

        let navigationIntentCount = navigationRequests.count + parseErrors.count
        guard navigationIntentCount > 0 else { return false }

        guard navigationIntentCount == 1 else {
#if DEBUG
            cmuxDebugLog("navigationURL.ignored reason=multipleLinks count=\(urls.count) intents=\(navigationIntentCount)")
#endif
            return true
        }

        if let parseError = parseErrors.first {
#if DEBUG
            cmuxDebugLog("navigationURL.blocked reason=\(parseError.error) url=\(parseError.url.absoluteString.prefix(160))")
#endif
            return true
        }

        if let request = navigationRequests.first {
            _ = handleCmuxNavigationURLRequest(request)
        }
        return true
    }

    @discardableResult
    private func handleCmuxNavigationURLRequest(_ request: CmuxNavigationURLRequest) -> Bool {
        let workspaceId: UUID
        switch request.target {
        case .workspace(let id), .pane(let id, _), .surface(let id, _):
            workspaceId = id
        }

        guard let context = mainWindowContexts.values.first(where: { context in
            context.tabManager.tabs.contains(where: { $0.id == workspaceId })
        }),
              let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceId }),
              let window = context.window ?? windowForMainWindowId(context.windowId) else {
#if DEBUG
            cmuxDebugLog("navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8))")
#endif
            return false
        }

        let targetPanelId: UUID?
        switch request.target {
        case .workspace:
            targetPanelId = nil
        case .pane(_, let paneId):
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
#if DEBUG
                cmuxDebugLog(
                    "navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8)) " +
                    "pane=\(paneId.uuidString.prefix(8))"
                )
#endif
                return false
            }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: pane)
                ?? workspace.bonsplitController.tabs(inPane: pane).first
            targetPanelId = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }
            if targetPanelId == nil {
                workspace.bonsplitController.focusPane(pane)
            }
        case .surface(_, let surfaceId):
            guard workspace.panels[surfaceId] != nil,
                  workspace.surfaceIdFromPanelId(surfaceId) != nil else {
#if DEBUG
                cmuxDebugLog(
                    "navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8)) " +
                    "surface=\(surfaceId.uuidString.prefix(8))"
                )
#endif
                return false
            }
            targetPanelId = surfaceId
        }

        prepareForExplicitOpenIntentAtStartup()
        setActiveMainWindow(window)
        _ = focusMainWindow(windowId: context.windowId)
        context.tabManager.focusTab(
            workspaceId,
            surfaceId: targetPanelId,
            suppressFlash: true
        )

#if DEBUG
        let surface = targetPanelId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        cmuxDebugLog(
            "navigationURL.focus workspace=\(workspaceId.uuidString.prefix(8)) " +
            "surface=\(surface) window=\(context.windowId.uuidString.prefix(8))"
        )
#endif
        return true
    }

    @discardableResult
    func handleCmuxSSHURLs(from urls: [URL]) -> Bool {
        var sshURLRequests: [CmuxSSHURLRequest] = []
        var sshURLParseErrors: [CmuxSSHURLParseError] = []
        for url in urls {
            switch CmuxSSHURLRequest.parse(url) {
            case .success(.some(let request)):
                sshURLRequests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                sshURLParseErrors.append(error)
            }
        }
        let sshURLIntentCount = sshURLRequests.count + sshURLParseErrors.count
        guard sshURLIntentCount > 0 else { return false }

        if sshURLIntentCount > 1 {
            showCmuxSSHURLParseError(.multipleLinks)
        } else {
            for error in sshURLParseErrors {
                showCmuxSSHURLParseError(error)
            }
            if let request = sshURLRequests.first {
                handleCmuxSSHURLRequest(request)
            }
        }
        return true
    }

    @discardableResult
    func handleCmuxTextURLs(from urls: [URL]) -> Bool {
        var textURLRequests: [CmuxTextURLRequest] = []
        var textURLParseErrors: [CmuxTextURLParseError] = []
        for url in urls {
            switch CmuxTextURLRequest.parse(url) {
            case .success(.some(let request)):
                textURLRequests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                textURLParseErrors.append(error)
            }
        }
        let textURLIntentCount = textURLRequests.count + textURLParseErrors.count
        guard textURLIntentCount > 0 else { return false }

        if textURLIntentCount > 1 {
            showCmuxTextURLParseError(.multipleLinks)
        } else {
            for error in textURLParseErrors {
                showCmuxTextURLParseError(error)
            }
            if let request = textURLRequests.first {
                handleCmuxTextURLRequest(request)
            }
        }
        return true
    }

    private func handleCmuxSSHURLRequest(_ request: CmuxSSHURLRequest) {
#if DEBUG
        let target = request.originalURL.host ?? request.originalURL.path
        cmuxDebugLog("sshURL.prompt target=\(target) destinationLength=\(request.destination.count) hasPort=\(request.port != nil)")
#endif

        deferInitialMainWindowBootstrapForExternalConfirmation()
        guard confirmCmuxSSHURLRequest(request) else {
            resumeInitialMainWindowBootstrapAfterExternalConfirmation(debugSource: "sshURL.cancelled")
#if DEBUG
            cmuxDebugLog("sshURL.cancelled")
#endif
            return
        }

        prepareForExplicitOpenIntentAtStartup()
        bootstrapInitialMainWindowAfterAcceptedExternalOpen(debugSource: "sshURL.confirmed")
        NSApp.activate(ignoringOtherApps: true)
        _ = CmuxSSHURLProcessLauncher.shared.start(
            request: request,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    private func handleCmuxTextURLRequest(_ request: CmuxTextURLRequest) {
#if DEBUG
        let target = request.originalURL.host ?? request.originalURL.path
        cmuxDebugLog("textURL.prompt target=\(target) kind=\(request.kind.rawValue) textLength=\(request.text.count)")
#endif

        deferInitialMainWindowBootstrapForExternalConfirmation()
        guard confirmCmuxTextURLRequest(request) else {
            resumeInitialMainWindowBootstrapAfterExternalConfirmation(debugSource: "textURL.cancelled")
#if DEBUG
            cmuxDebugLog("textURL.cancelled")
#endif
            return
        }

        prepareForExplicitOpenIntentAtStartup()
        bootstrapInitialMainWindowAfterAcceptedExternalOpen(
            debugSource: "textURL.confirmed",
            shouldActivate: !request.noFocus,
            suppressWelcome: true
        )
        if !request.noFocus {
            NSApp.activate(ignoringOtherApps: true)
        }
        let didPaste = pasteTextInPreferredMainWindowFromExternalLink(
            request.pasteText,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            shouldBringToFront: !request.noFocus,
            debugSource: "textURL.\(request.kind.rawValue)",
            onSendFailure: { [weak self] in
                self?.showCmuxTextURLPasteFailure(request)
            }
        )
        if !didPaste {
            showCmuxTextURLPasteFailure(request)
        }
    }

    private func confirmCmuxSSHURLRequest(_ request: CmuxSSHURLRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.sshURL.title",
            defaultValue: "Open SSH Workspace in cmux?"
        )
        alert.informativeText = String(
            format: String(
                localized: "dialog.sshURL.message",
                defaultValue: "An external link wants to open \"%@\" in cmux. Do you want to open this SSH workspace?\n\nIf you did not initiate this request, it may represent an attempted attack on your system. Only continue if you explicitly started this action."
            ),
            request.displayTarget
        )

        let cancelTitle = String(localized: "dialog.sshURL.cancel", defaultValue: "No")
        let runTitle = String(localized: "dialog.sshURL.run", defaultValue: "Open")
        alert.addButton(withTitle: cancelTitle)
        alert.addButton(withTitle: runTitle)

        let cancelButton = alert.buttons[0]
        cancelButton.keyEquivalent = "\r"
        if alert.buttons.count > 1 {
            let connectButton = alert.buttons[1]
            connectButton.keyEquivalent = ""
            connectButton.isEnabled = false
        }

        let gate = CmuxSSHURLConfirmationGate()
        if alert.buttons.count > 1 {
            gate.connectButton = alert.buttons[1]
        }
        alert.accessoryView = cmuxSSHURLAccessoryView(request: request, gate: gate)
        let response: NSApplication.ModalResponse = withExtendedLifetime(gate) {
            alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }

    private func confirmCmuxTextURLRequest(_ request: CmuxTextURLRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.kind == .prompt
            ? String(localized: "dialog.textURL.prompt.title", defaultValue: "Paste a Prompt From an External Link?")
            : String(localized: "dialog.textURL.rules.title", defaultValue: "Paste Rules From an External Link?")

        let scheme = request.originalURL.scheme ?? AuthEnvironment.callbackScheme
        let messageFormat = request.kind == .prompt
            ? String(
                localized: "dialog.textURL.prompt.message",
                defaultValue: "A %@:// link is asking cmux to paste a prompt into the current workspace. cmux cannot verify which website or app opened this link.\n\ncmux will paste the text into the terminal and will not press Return. Only continue if you trust this prompt."
            )
            : String(
                localized: "dialog.textURL.rules.message",
                defaultValue: "A %@:// link is asking cmux to paste rules into the current workspace. cmux cannot verify which website or app opened this link.\n\ncmux will paste the rules into the terminal and will not write files or press Return. Only continue if you trust these rules."
            )
        alert.informativeText = String(
            format: messageFormat,
            scheme
        )

        alert.addButton(withTitle: String(localized: "dialog.textURL.cancel", defaultValue: "Cancel"))
        alert.addButton(withTitle: String(localized: "dialog.textURL.paste", defaultValue: "Paste"))

        let cancelButton = alert.buttons[0]
        cancelButton.keyEquivalent = "\r"
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = ""
        }

        alert.accessoryView = cmuxTextURLAccessoryView(request: request)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func cmuxSSHURLAccessoryView(
        request: CmuxSSHURLRequest,
        gate: CmuxSSHURLConfirmationGate
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let targetLabel = NSTextField(labelWithString: String(
            format: String(localized: "dialog.sshURL.targetLabel", defaultValue: "SSH target: %@"),
            request.displayTarget
        ))
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.maximumNumberOfLines = 1

        let commandLabel = NSTextField(labelWithString: String(
            localized: "dialog.sshURL.commandLabel",
            defaultValue: "Command preview:"
        ))
        commandLabel.font = GlobalFontMagnification.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

        let socketPath = CmuxSSHURLProcessLauncher.shared.resolvedSocketPath()
        let commandScrollView = cmuxSSHURLTextPreview(request.cliPreview(socketPath: socketPath), height: 80)

        stack.addArrangedSubview(targetLabel)
        stack.addArrangedSubview(commandLabel)
        stack.addArrangedSubview(commandScrollView)

        let checkbox = NSButton(
            checkboxWithTitle: String(
                localized: "dialog.sshURL.checkbox",
                defaultValue: "I trust this SSH target and want cmux to connect."
            ),
            target: gate,
            action: #selector(CmuxSSHURLConfirmationGate.checkboxChanged(_:))
        )
        checkbox.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(checkbox)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 156))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            targetLabel.widthAnchor.constraint(equalTo: container.widthAnchor),
            commandScrollView.widthAnchor.constraint(equalTo: container.widthAnchor),
            checkbox.widthAnchor.constraint(equalTo: container.widthAnchor)
        ])
        return container
    }

    private func cmuxTextURLAccessoryView(request: CmuxTextURLRequest) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let localizedKind = request.kind == .prompt
            ? String(localized: "dialog.textURL.kind.prompt", defaultValue: "Prompt")
            : String(localized: "dialog.textURL.kind.rules", defaultValue: "Rules")
        let displayTitle = request.name ?? request.title
        let kindLabel = NSTextField(labelWithString: String(
            format: String(localized: "dialog.textURL.kindLabel", defaultValue: "Link type: %@"),
            localizedKind
        ))
        kindLabel.lineBreakMode = .byTruncatingTail
        kindLabel.maximumNumberOfLines = 1

        let titleLabel = displayTitle.map { displayTitle in
            let label = NSTextField(labelWithString: String(
                format: String(localized: "dialog.textURL.titleLabel", defaultValue: "Title: %@"),
                displayTitle
            ))
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            return label
        }

        let previewLabel = NSTextField(labelWithString: String(
            localized: "dialog.textURL.previewLabel",
            defaultValue: "Text preview:"
        ))
        previewLabel.font = GlobalFontMagnification.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

        let preview = cmuxSSHURLTextPreview(request.pasteText, height: 180)

        stack.addArrangedSubview(kindLabel)
        if let titleLabel {
            stack.addArrangedSubview(titleLabel)
        }
        stack.addArrangedSubview(previewLabel)
        stack.addArrangedSubview(preview)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 238))
        container.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            kindLabel.widthAnchor.constraint(equalTo: container.widthAnchor),
            preview.widthAnchor.constraint(equalTo: container.widthAnchor)
        ]
        if let titleLabel {
            constraints.append(titleLabel.widthAnchor.constraint(equalTo: container.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func cmuxSSHURLTextPreview(_ text: String, height: CGFloat) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.font = GlobalFontMagnification.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: height))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(equalToConstant: height)
        ])
        return scrollView
    }

    private func showCmuxSSHURLParseError(_ error: CmuxSSHURLParseError) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "dialog.sshURL.blocked.title",
            defaultValue: "cmux SSH Link Blocked"
        )
        alert.informativeText = cmuxSSHURLParseErrorMessage(error)
        alert.addButton(withTitle: String(localized: "dialog.sshURL.blocked.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func showCmuxTextURLPasteFailure(_ request: CmuxTextURLRequest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.kind == .prompt
            ? String(localized: "dialog.textURL.prompt.pasteFailed.title", defaultValue: "Couldn't Paste Prompt Link")
            : String(localized: "dialog.textURL.rules.pasteFailed.title", defaultValue: "Couldn't Paste Rules Link")
        alert.informativeText = String(
            localized: "dialog.textURL.pasteFailed.message",
            defaultValue: "cmux could not send the link text to a terminal."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func showCmuxTextURLParseError(_ error: CmuxTextURLParseError) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "dialog.textURL.blocked.title",
            defaultValue: "cmux Link Blocked"
        )
        alert.informativeText = cmuxTextURLParseErrorMessage(error)
        alert.addButton(withTitle: String(localized: "dialog.textURL.blocked.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func cmuxSSHURLParseErrorMessage(_ error: CmuxSSHURLParseError) -> String {
        switch error {
        case .missingDestination:
            return String(
                localized: "dialog.sshURL.error.missingDestination",
                defaultValue: "The link did not include an SSH host."
            )
        case .destinationTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.sshURL.error.destinationTooLong", defaultValue: "The SSH target is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .destinationContainsUnsafeCharacters:
            return String(
                localized: "dialog.sshURL.error.destinationContainsUnsafeCharacters",
                defaultValue: "The SSH host or user contains unsupported or hidden characters, so cmux refused to use it."
            )
        case .destinationStartsWithDash:
            return String(
                localized: "dialog.sshURL.error.destinationStartsWithDash",
                defaultValue: "The SSH host or user cannot start with a dash."
            )
        case .titleTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.sshURL.error.titleTooLong", defaultValue: "The workspace title is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .titleContainsUnsafeCharacters:
            return String(
                localized: "dialog.sshURL.error.titleContainsControlCharacters",
                defaultValue: "The workspace title contains hidden control or formatting characters, so cmux refused to use it."
            )
        case .invalidPort:
            return String(
                localized: "dialog.sshURL.error.invalidPort",
                defaultValue: "The SSH port must be between 1 and 65535."
            )
        case .invalidIntegerParameter(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.invalidIntegerParameter", defaultValue: "The SSH link included an invalid integer value for parameter: %@"),
                parameter
            )
        case .invalidHostKeyPolicy(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.invalidHostKeyPolicy", defaultValue: "The SSH link included an invalid host key policy for parameter: %@"),
                parameter
            )
        case .invalidBooleanParameter(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.invalidBooleanParameter", defaultValue: "The SSH link included an invalid boolean value for parameter: %@"),
                parameter
            )
        case .conflictingDestinationParameters:
            return String(
                localized: "dialog.sshURL.error.conflictingDestinationParameters",
                defaultValue: "The link included conflicting SSH target fields."
            )
        case .conflictingTitleParameters:
            return String(
                localized: "dialog.sshURL.error.conflictingTitleParameters",
                defaultValue: "The link included both title and name. Use only one workspace title field."
            )
        case .duplicateParameter(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.duplicateParameter", defaultValue: "The SSH link repeated a parameter: %@"),
                parameter
            )
        case .unsupportedParameter(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.unsupportedParameter", defaultValue: "The SSH link included an unsupported parameter: %@"),
                parameter
            )
        case .multipleLinks:
            return String(
                localized: "dialog.sshURL.error.multipleLinks",
                defaultValue: "Only one SSH link can be opened at a time."
            )
        }
    }

    private func cmuxTextURLParseErrorMessage(_ error: CmuxTextURLParseError) -> String {
        switch error {
        case .missingText:
            return String(
                localized: "dialog.textURL.error.missingText",
                defaultValue: "The link did not include text."
            )
        case .textTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.textURL.error.textTooLong", defaultValue: "The link text is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .textContainsUnsafeCharacters:
            return String(
                localized: "dialog.textURL.error.textContainsUnsafeCharacters",
                defaultValue: "The link text contains unsupported or hidden characters, so cmux refused to use it."
            )
        case .nameTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.textURL.error.nameTooLong", defaultValue: "The link name is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .nameContainsUnsafeCharacters:
            return String(
                localized: "dialog.textURL.error.nameContainsUnsafeCharacters",
                defaultValue: "The link name contains hidden control or formatting characters, so cmux refused to use it."
            )
        case .titleTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.textURL.error.titleTooLong", defaultValue: "The link title is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .titleContainsUnsafeCharacters:
            return String(
                localized: "dialog.textURL.error.titleContainsUnsafeCharacters",
                defaultValue: "The link title contains hidden control or formatting characters, so cmux refused to use it."
            )
        case .invalidBooleanParameter(let parameter):
            return String(
                format: String(localized: "dialog.textURL.error.invalidBooleanParameter", defaultValue: "The link included an invalid boolean value for parameter: %@"),
                parameter
            )
        case .duplicateParameter(let parameter):
            return String(
                format: String(localized: "dialog.textURL.error.duplicateParameter", defaultValue: "The link repeated a parameter: %@"),
                parameter
            )
        case .unsupportedParameter(let parameter):
            return String(
                format: String(localized: "dialog.textURL.error.unsupportedParameter", defaultValue: "The link included an unsupported parameter: %@"),
                parameter
            )
        case .multipleLinks:
            return String(
                localized: "dialog.textURL.error.multipleLinks",
                defaultValue: "Only one cmux external link can be opened at a time."
            )
        }
    }
}
