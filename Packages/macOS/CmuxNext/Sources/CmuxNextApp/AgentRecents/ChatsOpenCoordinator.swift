import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The one user-initiated Open Chat path shared by sidebar and palette.
@MainActor
final class ChatsOpenCoordinator {
    private weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    func open(_ key: String) {
        guard let services, let environment = QuitAgents.environment(services) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let plan = try await environment.chatOpenPlan(key: key) else { return }
                await dispatch(plan, key: key, environment: environment)
            } catch {
                services.refusalHUD.show(error.localizedDescription, in: services.windows.active?.window ?? NSApp.keyWindow)
            }
        }
    }

    private func dispatch(_ plan: AcpmuxChatOpenPlan, key: String, environment: AcpmuxEnvironment) async {
        guard let services else { return }
        switch plan.action {
        case .needsFolder(let reason):
            guard let folder = await chooseFolder(reason: reason) else { return }
            do {
                guard let next = try await environment.chatOpenPlan(key: key, cwd: folder) else { return }
                await dispatch(next, key: key, environment: environment)
            } catch {
                services.refusalHUD.show(error.localizedDescription, in: services.windows.active?.window ?? NSApp.keyWindow)
            }
        case .adopt(let adopt, let cwd, _):
            guard let pane = services.windows.active?.focusedPane else { return }
            pane.openAgentTab(seed: AgentPaneSeedSource(AgentPaneSeed(cwd: cwd, adopt: adopt)), linked: true)
        case .terminal(let argv, let env, let cwd):
            guard let pane = services.windows.active?.focusedPane,
                  let workspace = services.workspaceKey(of: pane.pane),
                  let connection = pane.daemon.connection else { return }
            services.registry.track(Task {
                do {
                    let created = try await connection.createTerminal(in: workspace, cwd: cwd, argv: argv, env: env)
                    if let surface = created.surface {
                        pane.selectWhenReported(surface: surface)
                    }
                    return nil
                } catch {
                    return ActionWorkFailure("open chat", error)
                }
            })
        case .readOnly(let path):
            guard let pane = services.windows.active?.focusedPane else { return }
            _ = services.viewers.markdownPages.open(URL(fileURLWithPath: path), in: pane, focus: true, userChose: false)
        }
    }

    private func chooseFolder(reason: String) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = reason
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url?.path : nil)
            }
        }
    }
}
