import Foundation

/// Carries the git checkout holding the session cwd from one endpoint to the other.
///
/// The source working tree (tracked, modified, deleted and untracked
/// non-ignored files) is recorded as a snapshot commit on top of HEAD at
/// `refs/agent-move/<id>`, sent with git over SSH, and checked out on the
/// destination: HEAD at the source commit (on the same branch when that is
/// safe), working tree at the snapshot, index at HEAD. Ignored files do not move.
struct AgentMoveCodeSync {
    let mover: AgentSessionMover
    let sessionID: String
    let pathMap: AgentMovePathMap
    private let scripts = AgentMoveScripts()

    init(mover: AgentSessionMover, sessionID: String, pathMap: AgentMovePathMap) {
        self.mover = mover
        self.sessionID = sessionID
        self.pathMap = pathMap
    }

    private var ref: String { "refs/agent-move/\(sessionID)" }
    private var incomingRef: String { "refs/agent-move/incoming/\(sessionID)" }
    private var outgoingRef: String { "refs/agent-move/outgoing/\(sessionID)" }

    func carry(
        from source: AgentMoveEndpoint,
        workingDirectory: String,
        to destination: AgentMoveEndpoint
    ) throws -> AgentMoveCodeOutcome {
        let top = try mover.shell(source, scripts.checkoutTop(workingDirectory)).trimmedOutput
        guard !top.isEmpty else { return .notGitCheckout(path: workingDirectory) }
        try mover.requirePlain(top)
        let destinationTop = pathMap.destinationPath(for: top)
        try mover.requirePlain(destinationTop)

        let addedWorktree = try ensureDestinationCheckout(source: source, top: top, destination: destination, destinationTop: destinationTop)
        let resetFrom = try destinationResetPoint(destination: destination, checkout: destinationTop)

        let snapshotResult = try mover.shell(source, scripts.snapshot(checkout: top, ref: outgoingRef, sessionID: sessionID))
        guard snapshotResult.succeeded,
              let snapshot = mover.marker("AM_SNAP", in: snapshotResult.standardOutput), !snapshot.isEmpty,
              let head = mover.marker("AM_HEAD", in: snapshotResult.standardOutput), !head.isEmpty else {
            throw AgentMoveError.gitFailed(step: "snapshot", detail: snapshotResult.failureDetail)
        }
        let branchValue = mover.marker("AM_BRANCH", in: snapshotResult.standardOutput) ?? ""
        let branch = branchValue.isEmpty ? nil : branchValue

        try transfer(source: source, top: top, destination: destination, destinationTop: destinationTop, snapshot: snapshot)

        let applied = try mover.shell(destination, scripts.apply(
            checkout: destinationTop,
            head: head,
            branch: branch,
            snapshot: snapshot,
            ref: ref,
            incomingRef: incomingRef,
            resetFrom: resetFrom
        ))
        guard applied.succeeded else {
            if applied.standardOutput.contains("AM_DIVERGED"), let branch {
                throw AgentMoveError.destinationBranchDiverged(branch: branch)
            }
            throw AgentMoveError.gitFailed(step: "apply", detail: applied.failureDetail)
        }
        // Only now does the source ref say "the destination holds this tree"; a
        // refused or failed move leaves the source's previous record untouched.
        let promoted = try mover.shell(source, scripts.promoteSnapshot(checkout: top, outgoingRef: outgoingRef, ref: ref, snapshot: snapshot))
        guard promoted.succeeded else { throw AgentMoveError.gitFailed(step: "update-ref", detail: promoted.failureDetail) }
        return .synced(checkout: destinationTop, head: head, branch: branch, snapshot: snapshot, addedWorktree: addedWorktree)
    }

    /// Uses an existing destination checkout, or adds a worktree of the same repository.
    private func ensureDestinationCheckout(
        source: AgentMoveEndpoint,
        top: String,
        destination: AgentMoveEndpoint,
        destinationTop: String
    ) throws -> Bool {
        if try mover.shell(destination, scripts.isCheckout(destinationTop)).succeeded { return false }
        let common = try mover.shell(source, scripts.commonGitDirectory(checkout: top))
        guard common.succeeded, !common.trimmedOutput.isEmpty else {
            throw AgentMoveError.gitFailed(step: "rev-parse", detail: common.failureDetail)
        }
        let destinationCommon = pathMap.destinationPath(for: common.trimmedOutput)
        guard try mover.shell(destination, scripts.isRepository(gitDirectory: destinationCommon)).succeeded else {
            throw AgentMoveError.destinationRepositoryMissing(checkout: destinationTop, repository: destinationCommon)
        }
        mover.report(.addingWorktree(path: destinationTop))
        let added = try mover.shell(destination, scripts.addWorktree(gitDirectory: destinationCommon, path: destinationTop))
        guard added.succeeded else {
            throw AgentMoveError.worktreeAddFailed(path: destinationTop, detail: added.failureDetail)
        }
        return true
    }

    /// The destination must be clean, or hold exactly the last snapshot it got for
    /// this session. Returns that snapshot commit when the tree still holds it.
    private func destinationResetPoint(destination: AgentMoveEndpoint, checkout: String) throws -> String? {
        let tree = try mover.shell(destination, scripts.workingTreeTree(checkout: checkout))
        guard tree.succeeded else { throw AgentMoveError.gitFailed(step: "write-tree", detail: tree.failureDetail) }
        let trees = try mover.shell(destination, scripts.headAndRefTrees(checkout: checkout, ref: ref))
        guard trees.succeeded else { throw AgentMoveError.gitFailed(step: "rev-parse", detail: trees.failureDetail) }
        let parts = trees.standardOutput.components(separatedBy: "\n\n")
        let headTree = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previousTree = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let workingTree = tree.trimmedOutput
        if workingTree == headTree { return nil }
        guard !previousTree.isEmpty, workingTree == previousTree else {
            throw AgentMoveError.destinationCheckoutDirty(path: checkout)
        }
        return ref
    }

    /// Sends the snapshot's objects directly between this machine and the host.
    private func transfer(
        source: AgentMoveEndpoint,
        top: String,
        destination: AgentMoveEndpoint,
        destinationTop: String,
        snapshot: String
    ) throws {
        var environment: [String: String] = [:]
        for case .ssh(let target) in [source, destination] {
            environment["GIT_SSH_COMMAND"] = target.sshCommandLine
        }
        let invocation: AgentMoveInvocation
        if source.isLocal {
            invocation = AgentMoveInvocation(
                arguments: ["git", "-C", top, "push", "-q", destination.transferPath(destinationTop), "+\(snapshot):\(incomingRef)"],
                environment: environment
            )
        } else {
            invocation = AgentMoveInvocation(
                arguments: ["git", "-C", destinationTop, "fetch", "-q", source.transferPath(top), "+\(outgoingRef):\(incomingRef)"],
                environment: environment
            )
        }
        let result = try mover.run(invocation)
        guard result.succeeded else {
            throw AgentMoveError.gitFailed(step: source.isLocal ? "push" : "fetch", detail: result.failureDetail)
        }
    }
}
