import Foundation

/// The page's git reads (`git.*` on the session host, the folder's GitHub repository), the Changes
/// view's Stage and Create PR, and its acpmux socket requests (`transport.*`): open the handshake's connection once, send frames,
/// reserve and release gesture tickets, close.
@MainActor
enum AgentPaneTransportReply {
    static func reply(to request: AgentPaneRequest, in model: AgentPaneModel) async -> [String: Any] {
        switch request {
        case .git(let git):
            guard let onGit = model.onGit else { return AgentPaneModel.gitFailure(.notConnected) }
            do {
                let data = try await onGit(git)
                // A git.diff with patches can be many megabytes: parse it off the main actor (cx-9c8m).
                guard let value = await AgentPaneModel.parseGitReply(data)?.value else {
                    return AgentPaneModel.gitFailure(.failed)
                }
                return AgentPaneReply.success(value)
            } catch {
                return AgentPaneModel.gitFailure(error as? AgentPaneGitFailure ?? .failed)
            }
        case .invalidGit(let method):
            let message = AgentPaneGitWrite.methods.contains(method) ? AgentPaneModel.gitWriteFailedMessage : AgentPaneModel.gitFailedMessage
            return AgentPaneModel.gitFailure(.invalidRequest, message: message)
        case .gitStage(let stage): return await AgentPaneGitStage.reply(to: stage, in: model)
        case .gitPullRequest(let pullRequest): return await AgentPaneGitPullRequest.reply(to: pullRequest, in: model)
        case .githubRepository(let cwd): return AgentPaneReply.success(["repository": (await AgentPaneGitHubRepository.read(at: cwd)).map { $0 as Any } ?? NSNull()])
        case .transportOpen:
            guard let connection = model.pendingConnection else { return AgentPaneModel.transportFailure(.noConnection) }
            model.pendingConnection = nil
            do {
                return AgentPaneReply.success(["connection": try await model.transport.open(connection)])
            } catch {
                return AgentPaneModel.transportFailure(error)
            }
        case .transportSend(let connection, let frames):
            return AgentPaneModel.transportReply(await model.transport.send(connection: connection, frames: frames))
        case .transportGesture(let intent):
            guard let intent else { return AgentPaneModel.transportFailure(.intentInvalid) }
            guard let ticket = model.transport.reserveGesture(intent) else { return AgentPaneModel.transportFailure(.gestureRequired) }
            return AgentPaneReply.success(["ticket": ticket])
        case .transportGestureRelease: return model.endTransport(closing: nil)
        case .transportClose(let connection): return model.endTransport(closing: connection)
        // This Mac's agent CLIs (cx-1mbnu): never for a chat on another machine.
        case .harnessUpdate, .harnessRestart:
            if model.remoteChat { return AgentPaneModel.unsupported("harness") }
            return await AgentPaneHarnessCard.reply(to: request, transport: model.transport, session: model.sessionId)
        default: return AgentPaneModel.unsupported(String(describing: request))
        }
    }
}
