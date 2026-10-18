import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI

/// Shows one "Open Repository in Cloud…" sheet at a time, like
/// ``CloudSecretsSheetPresenter``. Every entrypoint (Cloud menu, command palette, the
/// Cloud panel's button, paste or drop on the panel, a `cmux://cloud/clone` link) comes
/// here, and Run goes through ``launch(_:preferredWindow:)``: one path into the bundled
/// CLI's `vm clone`.
@MainActor
final class CloudOpenRepositoryPresenter {
    static let shared = CloudOpenRepositoryPresenter()

    private var sheetWindow: NSWindow?
    private var sheetController: CloudSheetWindow?
    private var hostWindow: NSWindow?
    private var model: CloudOpenRepositorySheetModel?
    private var loadTask: Task<Void, Never>?

    private init() {}

#if DEBUG
    var debugOpenModel: CloudOpenRepositorySheetModel? { model }
#endif

    /// Opens the sheet. With no `repository`, a GitHub link on the clipboard prefills
    /// the field. An open sheet takes a new prefill instead of stacking a second one.
    func present(
        repository: String? = nil,
        agent: CloudOpenRepositoryCommand.Agent? = nil,
        prompt: String? = nil,
        preferredWindow: NSWindow?
    ) {
        let prefill = repository ?? Self.clipboardRepository() ?? ""
        if let model, sheetWindow != nil {
            if repository != nil {
                model.repositoryText = prefill
            }
            if let agent { model.agent = agent }
            if let prompt { model.prompt = prompt }
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        let model = CloudOpenRepositorySheetModel(
            repository: prefill,
            agent: agent,
            prompt: prompt,
            backend: Self.backend(preferredWindow: preferredWindow)
        )
        model.onRun = { [weak self] command in
            self?.launch(command, preferredWindow: self?.hostWindow ?? preferredWindow) ?? false
        }
        model.onFinished = { [weak self] in self?.dismiss() }
        let sheet = CloudSheetWindow(rootView: CloudOpenRepositorySheet(model: model))
        let window = sheet.window
        window.styleMask = [.titled]
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.title = String(localized: "cloudOpenRepository.title", defaultValue: "Open Repository in Cloud")
        window.isReleasedWhenClosed = false
        self.model = model
        sheetController = sheet
        sheetWindow = window
        loadTask = Task { [weak model] in await model?.load() }

        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: preferredWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            sheet.beginSheet(on: host)
        } else {
            hostWindow = nil
            sheet.orderFrontFloating()
        }
    }

    /// Opens the sheet for pasted or dropped text when it names a GitHub repository.
    /// Returns false (and opens nothing) otherwise, so the caller can fall through.
    @discardableResult
    func presentIfGitHubRepository(text: String, preferredWindow: NSWindow?) -> Bool {
        guard let field = CloudOpenRepositoryReference.gitHubFieldText(fromPasteboardText: text) else { return false }
        present(repository: field, preferredWindow: preferredWindow)
        return true
    }

    private func dismiss() {
        loadTask?.cancel()
        loadTask = nil
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetController = nil
        sheetWindow = nil
        hostWindow = nil
        model = nil
    }

    // MARK: Run

    /// Types the clone command into a new local workspace's terminal. The bundled CLI
    /// does the rest and opens the Cloud workspace when the checkout is ready; this
    /// terminal keeps the log, the setup confirmation and any failure with its fix.
    func launch(_ command: CloudOpenRepositoryCommand, preferredWindow: NSWindow?) -> Bool {
        guard let appDelegate = AppDelegate.shared,
              let cliPath = CLIForwardingLaunchRouter.bundledCLIURL()?.path else { return false }
        let input = command.shellLine(executable: cliPath) + "\n"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
#if DEBUG
        cmuxDebugLog(
            "cloudOpenRepository.launch project=\(command.reference.projectKey) " +
            "agent=\(command.agent?.rawValue ?? "none") hasPrompt=\(command.prompt != nil)"
        )
#endif
        if appDelegate.addWorkspaceInPreferredMainWindow(
            title: command.workspaceTitle,
            workingDirectory: home,
            initialTerminalInput: input,
            inheritWorkingDirectory: false,
            shouldBringToFront: true,
            debugSource: "cloudOpenRepository"
        ) != nil {
            return true
        }
        _ = appDelegate.createMainWindow(
            initialWorkspaceTitle: command.workspaceTitle,
            initialWorkingDirectory: home,
            initialTerminalInput: input
        )
        return true
    }

    // MARK: Backend

    private static func backend(preferredWindow: NSWindow?) -> CloudOpenRepositorySheetModel.Backend {
        CloudOpenRepositorySheetModel.Backend(
            loadGitTokenCoverage: {
                let service = CloudSecretsService.shared
                await service.reload()
                return CloudOpenRepositorySheetModel.GitTokenCoverage(records: service.records)
            },
            readGitHubCLIToken: {
                await CloudOpenRepositoryGitHubCLIToken.read(runner: CommandRunner())
            },
            storeGitHubToken: { token in
                let service = CloudSecretsService.shared
                // The clone syncs its own machine before git runs; other machines catch
                // up in the background when auto-sync is on, without holding the sheet.
                try await service.set(
                    [CloudSecretInput(name: "GH_TOKEN", value: token)],
                    scope: .all,
                    source: .ghCLI,
                    sync: false
                )
                if service.isAutoSyncEnabled {
                    Task { @MainActor in _ = await service.syncAllStale() }
                }
            },
            openSecrets: {
                CloudSecretsSheetPresenter.shared.present(preferredWindow: preferredWindow)
            }
        )
    }

    private static func clipboardRepository() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        return CloudOpenRepositoryReference.gitHubFieldText(fromPasteboardText: text)
    }
}

/// `gh auth token`, read through a pipe: the token is never in argv, a log, or an
/// error message. The same source as `cmux vm secrets import --gh`.
enum CloudOpenRepositoryGitHubCLIToken {
    static let timeout: TimeInterval = 30

    static func read(runner: any CommandRunning) async -> String? {
        let result = await runner.run(
            directory: FileManager.default.homeDirectoryForCurrentUser.path,
            executable: "gh",
            arguments: ["auth", "token"],
            timeout: timeout
        )
        guard result.executionError == nil, !result.timedOut, result.exitStatus == 0 else { return nil }
        let token = (result.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isNewline) else { return nil }
        return token
    }
}
