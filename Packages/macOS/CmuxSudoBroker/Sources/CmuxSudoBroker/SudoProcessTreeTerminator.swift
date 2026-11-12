import Darwin
import Foundation

struct SudoProcessTreeTerminator: Sendable {
    private let inspector: any SudoProcessInspecting
    private let signaler: any SudoProcessSignaling
    private let exitWaiter: SudoProcessExitWaiter
    private let terminationGraceSeconds: TimeInterval
    private let killGraceSeconds: TimeInterval

    init(
        inspector: any SudoProcessInspecting,
        signaler: any SudoProcessSignaling,
        terminationGraceSeconds: TimeInterval = 1,
        killGraceSeconds: TimeInterval = 5
    ) {
        self.inspector = inspector
        self.signaler = signaler
        exitWaiter = SudoProcessExitWaiter(inspector: inspector)
        self.terminationGraceSeconds = terminationGraceSeconds
        self.killGraceSeconds = killGraceSeconds
    }

    /// Terminates a process generation, its descendants, and descendant PTY groups.
    ///
    /// - Parameter root: The generation-safe identity of the spawned `script` process.
    /// - Returns: Process generations that survived both bounded signal phases.
    func terminate(root: SudoProcessIdentity) -> [SudoProcessIdentity] {
        terminate(roots: [root])
    }

    /// Terminates several known generations as one deduplicated process forest.
    func terminate(roots: [SudoProcessIdentity]) -> [SudoProcessIdentity] {
        var targets = processForest(roots: roots)
        signal(targets, with: SIGTERM)

        let termSurvivors = exitWaiter.survivors(
            among: targets,
            after: terminationGraceSeconds
        )
        guard !termSurvivors.isEmpty else { return [] }

        // Expand from every generation captured before TERM. The original
        // wrapper can disappear during the grace period while a reparented PTY
        // descendant creates another child or process group.
        let expandedTargets = processForest(roots: targets)
        targets = Self.unique(targets + expandedTargets)
        let liveTargets = targets.filter(inspector.isRunning)
        signal(liveTargets, with: SIGKILL)
        return exitWaiter.survivors(among: liveTargets, after: killGraceSeconds)
    }

    private func processForest(roots: [SudoProcessIdentity]) -> [SudoProcessIdentity] {
        var identities: [SudoProcessIdentity] = []
        var pending = roots
        var seen: Set<SudoProcessIdentity> = []
        while let parent = pending.popLast() {
            guard seen.insert(parent).inserted else { continue }
            guard inspector.isRunning(parent) else { continue }
            identities.append(parent)
            for child in inspector.directChildProcessIdentifiers(
                of: parent.processIdentifier
            ) {
                guard let identity = inspector.identity(for: child) else { continue }
                pending.append(identity)
            }
        }
        return identities
    }

    private func signal(_ identities: [SudoProcessIdentity], with signal: Int32) {
        let live = identities.filter(inspector.isRunning)
        let callerGroup = getpgrp()
        var membersByGroup: [Int32: [SudoProcessIdentity]] = [:]
        for identity in live {
            guard let group = inspector.processGroupIdentifier(
                for: identity.processIdentifier
            ) else {
                continue
            }
            membersByGroup[group, default: []].append(identity)
        }
        for group in membersByGroup.keys.sorted() {
            guard group != callerGroup,
                  let members = membersByGroup[group],
                  members.contains(where: inspector.isRunning) else {
                continue
            }
            signaler.signal(processGroupIdentifier: group, signal: signal)
        }
        for identity in live.reversed() where inspector.isRunning(identity) {
            signaler.signal(processIdentifier: identity.processIdentifier, signal: signal)
        }
    }

    private static func unique(_ identities: [SudoProcessIdentity]) -> [SudoProcessIdentity] {
        var seen: Set<SudoProcessIdentity> = []
        return identities.filter { seen.insert($0).inserted }
    }
}
