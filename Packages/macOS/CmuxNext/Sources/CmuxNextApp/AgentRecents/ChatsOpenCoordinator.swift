import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Where Open Chat puts the chat: the focused pane (the palette), or a new
/// pane split to its right (the sidebar's All chats, Lawrence 2026-10-09).
enum ChatOpenPlacement: Sendable, Equatable {
    case currentPane
    case splitRight
}

/// The one user-initiated Open Chat path shared by sidebar and palette.
@MainActor
final class ChatsOpenCoordinator {
    private weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    func open(_ key: String, placement: ChatOpenPlacement = .currentPane) {
        guard let services, let environment = QuitAgents.environment(services) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let plan = try await environment.chatOpenPlan(key: key) else { return }
                await dispatch(plan, key: key, environment: environment, placement: placement)
            } catch {
                services.refusalHUD.show(error.localizedDescription, in: services.windows.active?.window ?? NSApp.keyWindow)
            }
        }
    }

    private func dispatch(_ plan: AcpmuxChatOpenPlan, key: String, environment: AcpmuxEnvironment,
                          placement: ChatOpenPlacement) async {
        guard let services else { return }
        switch plan.action {
        case .needsFolder(let reason):
            guard let folder = await chooseFolder(reason: reason) else { return }
            do {
                guard let next = try await environment.chatOpenPlan(key: key, cwd: folder) else { return }
                await dispatch(next, key: key, environment: environment, placement: placement)
            } catch {
                services.refusalHUD.show(error.localizedDescription, in: services.windows.active?.window ?? NSApp.keyWindow)
            }
        case .adopt(let adopt, let cwd, _):
            guard let pane = services.windows.active?.focusedPane else { return }
            let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: cwd, adopt: adopt))
            // The chat already open in a tab shows that tab, wherever it is.
            if placement == .splitRight, services.agentTabs.tab(resuming: adopt) == nil, splitFits(pane) {
                openAgentTabToTheRight(of: pane, seed: seed)
            } else {
                pane.openAgentTab(seed: seed, linked: true)
            }
        case .terminal(let argv, let env, let cwd):
            guard let pane = services.windows.active?.focusedPane,
                  let workspace = services.workspaceKey(of: pane.pane),
                  let connection = pane.daemon.connection else { return }
            let split = placement == .splitRight && splitFits(pane)
            let handle = pane.pane.handle
            let content = pane.workspace
            let intent = split ? content?.beginFocusIntent() : nil
            services.registry.track(Task {
                do {
                    if split {
                        let options = SpawnOptions(cwd: cwd, argv: argv, env: env, workspace: workspace)
                        let created = try await connection.split(handle, direction: .right, options: options)
                        content?.expectFocus(on: created.surface, generation: intent)
                        return nil
                    }
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

extension ChatsOpenCoordinator {
    /// Whether the focused pane has room for a split to its right; without
    /// room the chat opens as a tab in that pane (never a refusal).
    private func splitFits(_ pane: PaneController) -> Bool {
        guard let services else { return false }
        if case .split = services.splitRoom(for: pane.pane, edge: .right) { return true }
        return false
    }

    /// A new agent tab on the chat in `pane`, moved into a new pane split to
    /// its right once the store created it (the browser's new-split path).
    private func openAgentTabToTheRight(of pane: PaneController, seed: AgentPaneSeedSource) {
        guard let services else { return }
        let pending: AgentTabPending
        do {
            pending = try services.agentTabs.open(in: pane.pane.handle, of: pane.daemon, seed: seed, linked: true)
        } catch {
            services.registry.refuse((error as? AgentTabRefusal)?.message ?? RefusalStrings.agentTabCreateFailed)
            return
        }
        pane.selectWhenReported(surface: pending.surface)
        let context = AppActionContext(services: services)
        let model = pane.pane
        services.registry.track(Task {
            do {
                let created = try await pending.value()
                // Focus follows the chat into its new pane (a user click).
                pane.workspace?.focus.followMovedTab(created.key, from: pane.paneKey)
                PanePlacementRouting.moveToSplit(context, created.surface, of: model, direction: .right)
                return nil
            } catch {
                return ActionWorkFailure("open chat", error)
            }
        })
    }
}
