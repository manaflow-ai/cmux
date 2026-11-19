import Foundation

extension AgentPaneGitWriteReply {
    /// `github.repos.checkout {repo, candidates?, idempotency_key}`: a GitHub repository picked for a new chat on this
    /// Mac becomes its worktree. The checkout this Mac has of it, else a clone under `~/cmux/repos`
    /// (``AgentPaneGitHubCheckout``), then that checkout's new worktree for the chat, exactly as New Worktree makes one
    /// (``newWorktree(_:in:model:gestureSpent:)``). One click pays for both: a clone can outlast a gesture's lifetime.
    /// The reply is `git.worktree.create`'s, with `checkout` (the checkout's folder) and `cloned` beside its value.
    static func gitHubCheckout(repo: String, candidates: [String], key: String, userGesture: Bool, in model: AgentPaneModel) async -> [String: Any] {
        let message = AgentPaneModel.gitWriteFailedMessage
        // Only a new chat on this Mac: a Cloud or SSH chat's repository is that machine's to clone.
        guard !model.remoteChat, model.gitWritesHere?() == true else { return AgentPaneModel.gitFailure(.noSessionFolder, message: message) }
        guard model.sessionId == nil else { return AgentPaneModel.gitFailure(.sessionChanged, message: message) }
        guard let checkout = model.gitHub?.checkout else {
            return AgentPaneReply.failure(code: "github.unavailable", message: AgentPaneModel.gitHubUnavailableMessage)
        }
        // A clone writes to this Mac's disk: only on the person's own pick.
        guard userGesture || model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        // A clone can take minutes: a folder picked meanwhile (`workspace.useFolder`, another repository) wins, and this
        // pick then makes no worktree (the clone stays, for the next pick of it).
        let pick = model.beginPick()
        let found: AgentPaneGitHubCheckout.Checkout
        switch await checkout.checkout(repo: repo, candidates: candidates) {
        case .success(let checkout): found = checkout
        case .failure(.cloneFailed):
            return AgentPaneReply.failure(code: "github.clone_failed", message: AgentPaneModel.gitHubCloneFailedMessage(repo))
        case .failure(.noFolder):
            return AgentPaneReply.failure(code: "github.clone_no_folder", message: AgentPaneModel.gitHubCloneNoFolderMessage(repo))
        }
        guard pick == model.pickSequence, model.sessionId == nil else {
            return AgentPaneModel.gitFailure(.sessionChanged, message: message)
        }
        var reply = await newWorktree(.worktree(cwd: found.path, name: nil, key: key), in: found.path, model: model, gestureSpent: true)
        if var value = reply["value"] as? [String: Any] {
            value["checkout"] = found.path
            value["cloned"] = found.cloned
            reply["value"] = value
        }
        return reply
    }
}
