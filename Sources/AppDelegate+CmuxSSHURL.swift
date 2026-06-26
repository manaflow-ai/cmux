import AppKit
import CmuxRemoteWorkspace
import CmuxSettings
import CmuxWindowing
import CmuxWorkspaces
import Bonsplit
import Foundation

extension Notification.Name {
    static let defaultTerminalRegistrationDidChange = Notification.Name("DefaultTerminalRegistration.didChange")
}

// MARK: - Default-terminal registration (forwards to CmuxWindowing)

extension AppDelegate {
    /// Builds the composition-root ``DefaultTerminalRegistrationCoordinator``.
    /// The registration/dedup logic moved into `CmuxWindowing`; this is the
    /// single app-side construction site, injecting the registrar factory (live
    /// bundle URL + the `.defaultTerminalRegistrationDidChange` post so the
    /// default-terminal Settings/menu UI refreshes), the NSAlert failure
    /// presenter, and the DEBUG trace sink.
    func makeDefaultTerminalRegistrationCoordinator() -> DefaultTerminalRegistrationCoordinator {
#if DEBUG
        let debugLog: @Sendable (String) -> Void = { cmuxDebugLog($0) }
#else
        let debugLog: @Sendable (String) -> Void = { _ in }
#endif
        return DefaultTerminalRegistrationCoordinator(
            makeRegistrar: {
                DefaultTerminalRegistrar(
                    bundleURL: Bundle.main.bundleURL,
                    onRegistrationDidChange: {
                        NotificationCenter.default.post(
                            name: .defaultTerminalRegistrationDidChange,
                            object: nil
                        )
                    }
                )
            },
            onRegistrationFailure: { [weak self] error in
                self?.presentDefaultTerminalRegistrationError(error)
            },
            debugLog: debugLog
        )
    }

    /// The current default-terminal registration status, read through the
    /// composition-root coordinator. Reads do not fire the change notifier.
    static func defaultTerminalRegistrationStatus() -> DefaultTerminalRegistrationStatus {
        shared?.defaultTerminalRegistrationCoordinator.currentStatus()
            ?? DefaultTerminalRegistrationStatus(
                matchedTargetCount: 0,
                targetCount: DefaultTerminalRegistrar.targetCount
            )
    }

    /// Kicks off the "Make cmux the Default Terminal" flow through the
    /// composition-root coordinator (shared dedup across menu/palette).
    static func makeDefaultTerminal(debugSource: String) {
        shared?.defaultTerminalRegistrationCoordinator.setAsDefault(debugSource: debugSource)
    }

    private func presentDefaultTerminalRegistrationError(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.defaultTerminal.setFailed.title",
            defaultValue: "Could Not Set Default Terminal"
        )
        alert.informativeText = (error as? DefaultTerminalRegistrationError)?.localizedFailureDescription ?? String(
            localized: "defaultTerminal.updateFailed.message",
            defaultValue: "macOS could not update every default terminal handler."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.window.identifier = NSUserInterfaceItemIdentifier("cmux.defaultTerminalRegistrationError")
        alert.runModal()
    }
}

// MARK: - SSH-URL launch presentation (forwards to CmuxWorkspaces)

extension AppDelegate {
    /// Resolves the control socket the bundled `cmux ssh` CLI should target.
    /// Stays app-side because it reaches the live `TerminalController` socket
    /// state, which the package does not own.
    func resolvedSSHURLSocketPath() -> String {
        terminalControl.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
    }

    /// Launches `cmux ssh` for `request` through the composition-root
    /// ``CmuxSSHURLLaunchService``, supplying the bundled CLI URL, the resolved
    /// socket path, and an app-side failure presenter that binds the NSAlert to
    /// `preferredWindow` with app-bundle localized copy.
    @discardableResult
    func startCmuxSSHURLLaunch(request: CmuxSSHURLRequest, preferredWindow: NSWindow?) -> Bool {
        let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        return sshURLLaunchService.start(
            request: request,
            cliURL: cliURL,
            socketPath: resolvedSSHURLSocketPath(),
            onFailure: { [weak self, weak preferredWindow] failure in
                self?.presentCmuxSSHURLLaunchFailure(failure, preferredWindow: preferredWindow)
            }
        )
    }

    /// Presents a typed ``CmuxSSHURLLaunchFailure`` as an NSAlert with app-bundle
    /// localized copy. The localized `summary` strings stay here (resolving them
    /// in the package would bind to the package bundle and drop the Japanese
    /// translation).
    private func presentCmuxSSHURLLaunchFailure(
        _ failure: CmuxSSHURLLaunchFailure,
        preferredWindow: NSWindow?
    ) {
        let summary: String
        let output: String
        switch failure {
        case .missingCLI:
            summary = String(
                localized: "dialog.sshURL.launchFailed.missingCLI",
                defaultValue: "The bundled cmux CLI is missing from this app build."
            )
            output = ""
        case .nonzeroExit(let status, let exitOutput):
            let format = String(
                localized: "dialog.sshURL.launchFailed.exit",
                defaultValue: "cmux ssh exited with status %d."
            )
            summary = String(format: format, Int(status))
            output = exitOutput
        case .launchThrew(let description):
            summary = String(
                localized: "dialog.sshURL.launchFailed.launch",
                defaultValue: "cmux ssh could not be launched."
            )
            output = description
        }

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
        let intentCounts = CmuxExternalURLIntentCounts.classify(
            urls: urls,
            supportedSchemes: CmuxSSHURLRequest.activeSupportedSchemes
        )
        guard intentCounts.total > 0 else { return false }
        guard intentCounts.total == 1 else {
            switch intentCounts.multipleLinksError {
            case .ssh:
                showCmuxSSHURLParseError(.multipleLinks)
            case .text, nil:
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
        return false
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

        guard let context = registeredMainWindows.first(where: { context in
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
        let plan = CmuxDeepLinkDispatchPlan(parsing: urls, with: CmuxSSHURLRequest.parse)
        switch plan.resolution {
        case .empty:
            return false
        case .multipleLinks:
            showCmuxSSHURLParseError(.multipleLinks)
        case .single(let parseErrors, let request):
            for error in parseErrors {
                showCmuxSSHURLParseError(error)
            }
            if let request {
                handleCmuxSSHURLRequest(request)
            }
        }
        return true
    }

    @discardableResult
    func handleCmuxTextURLs(from urls: [URL]) -> Bool {
        let plan = CmuxDeepLinkDispatchPlan(parsing: urls, with: CmuxTextURLRequest.parse)
        switch plan.resolution {
        case .empty:
            return false
        case .multipleLinks:
            showCmuxTextURLParseError(.multipleLinks)
        case .single(let parseErrors, let request):
            for error in parseErrors {
                showCmuxTextURLParseError(error)
            }
            if let request {
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
        _ = startCmuxSSHURLLaunch(
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

    /// Builds the app-side ``CmuxExternalLinkPromptPresenter``, injecting the live
    /// control-socket resolver so the SSH command preview targets the running
    /// `TerminalController`'s socket.
    private func makeExternalLinkPromptPresenter() -> CmuxExternalLinkPromptPresenter {
        CmuxExternalLinkPromptPresenter(
            resolveSSHURLSocketPath: { [weak self] in
                self?.resolvedSSHURLSocketPath() ?? ""
            }
        )
    }

    private func confirmCmuxSSHURLRequest(_ request: CmuxSSHURLRequest) -> Bool {
        makeExternalLinkPromptPresenter().confirmSSHURLRequest(request)
    }

    private func confirmCmuxTextURLRequest(_ request: CmuxTextURLRequest) -> Bool {
        makeExternalLinkPromptPresenter().confirmTextURLRequest(request)
    }

    /// Builds the app-side ``CmuxExternalLinkErrorPresenter`` for the blocked or
    /// failed external-link alerts. The presenter is stateless, so a fresh
    /// instance per call mirrors the sibling ``makeExternalLinkPromptPresenter()``.
    private func makeExternalLinkErrorPresenter() -> CmuxExternalLinkErrorPresenter {
        CmuxExternalLinkErrorPresenter()
    }

    private func showCmuxSSHURLParseError(_ error: CmuxSSHURLParseError) {
        makeExternalLinkErrorPresenter().showSSHURLParseError(error)
    }

    private func showCmuxTextURLPasteFailure(_ request: CmuxTextURLRequest) {
        makeExternalLinkErrorPresenter().showTextURLPasteFailure(request)
    }

    private func showCmuxTextURLParseError(_ error: CmuxTextURLParseError) {
        makeExternalLinkErrorPresenter().showTextURLParseError(error)
    }
}
