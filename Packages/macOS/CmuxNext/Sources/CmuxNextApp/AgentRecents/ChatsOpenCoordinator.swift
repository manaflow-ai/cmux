import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextHistory
import Foundation

/// What Open Chat does with a daemon plan (Lawrence 2026-10-09): one click on a chat shows it in a
/// NEW WORKSPACE and focus moves there; a chat a tab already resumes shows that tab instead of a
/// duplicate. Pure, so the decision is tested without windows.
enum ChatOpenRoute: Equatable {
    /// The tab (`TabModel.id`) that already resumes this chat.
    case reveal(tab: String)
    /// A new workspace named `name`: its first tab is the adopted agent chat (`seed`), or a
    /// terminal that runs `command` (the harness's resume argv, shell-quoted) with `env`.
    case newWorkspace(name: String?, cwd: String?, seed: AgentPaneSeed?, command: String?, env: [String: String])
    case readOnly(path: String)
    case needsFolder(reason: String)

    static func route(_ plan: AcpmuxChatOpenPlan, title: String?, openTab: (AgentPaneAdopt) -> String?) -> ChatOpenRoute {
        switch plan.action {
        case .needsFolder(let reason): .needsFolder(reason: reason)
        case .readOnly(let path): .readOnly(path: path)
        case .adopt(let adopt, let cwd, _):
            openTab(adopt).map { .reveal(tab: $0) }
                ?? .newWorkspace(name: title, cwd: cwd, seed: AgentPaneSeed(cwd: cwd, adopt: adopt), command: nil, env: [:])
        case .terminal(let argv, let env, let cwd):
            .newWorkspace(name: title, cwd: cwd, seed: nil, command: argv.map(AgentResume.shellQuoted).joined(separator: " "), env: env)
        }
    }
}

/// The one user-initiated Open Chat path shared by the sidebar's All chats, the palette and the
/// New Tab cards.
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
        let title = services.chatsFeed?.chats.first { $0.id == key }?.title
        switch ChatOpenRoute.route(plan, title: title, openTab: { services.agentTabs.tab(resuming: $0) }) {
        case .needsFolder(let reason):
            guard let folder = await chooseFolder(reason: reason) else { return }
            do {
                guard let next = try await environment.chatOpenPlan(key: key, cwd: folder) else { return }
                await dispatch(next, key: key, environment: environment)
            } catch {
                services.refusalHUD.show(error.localizedDescription, in: services.windows.active?.window ?? NSApp.keyWindow)
            }
        case .reveal(let tab):
            _ = services.revealTab(tab)
        case .newWorkspace(let name, let cwd, let seed, let command, let env):
            var spawn = WorkspaceSpawn(cwd: cwd, name: name, command: command, env: env)
            spawn.firstChat = seed
            let windowID = services.windows.active?.state.id
            services.registry.track(Task { @MainActor in
                do {
                    _ = try await services.windows.createWorkspace(spawn, into: windowID)
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
