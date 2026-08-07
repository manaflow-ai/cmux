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
        var targets = processTree(root: root)
        signal(targets, with: SIGTERM)

        let termSurvivors = exitWaiter.survivors(
            among: targets,
            after: terminationGraceSeconds
        )
        guard !termSurvivors.isEmpty else { return [] }

        // Expand from every generation captured before TERM. The original
        // wrapper can disappear during the grace period while a reparented PTY
        // descendant creates another child or process group.
        let expandedTargets = targets.flatMap { processTree(root: $0) }
        targets = Self.unique(targets + expandedTargets)
        let liveTargets = targets.filter(inspector.isRunning)
        signal(liveTargets, with: SIGKILL)
        return exitWaiter.survivors(among: liveTargets, after: killGraceSeconds)
    }

    private func processTree(root: SudoProcessIdentity) -> [SudoProcessIdentity] {
        guard inspector.isRunning(root) else { return [] }
        var identities = [root]
        var pending = [root.processIdentifier]
        var seen = Set([root.processIdentifier])
        while let parent = pending.popLast() {
            for child in inspector.directChildProcessIdentifiers(of: parent)
            where seen.insert(child).inserted {
                guard let identity = inspector.identity(for: child) else { continue }
                identities.append(identity)
                pending.append(child)
            }
        }
        return identities
    }

    private func signal(_ identities: [SudoProcessIdentity], with signal: Int32) {
        let live = identities.filter(inspector.isRunning)
        let groups = Set(
            live.compactMap { identity in
                inspector.processGroupIdentifier(for: identity.processIdentifier)
            }
        )
        for group in groups.sorted() {
            guard live.contains(where: { identity in
                inspector.isRunning(identity)
                    && inspector.processGroupIdentifier(for: identity.processIdentifier) == group
            }) else {
                continue
            }
            signaler.signal(processGroupIdentifier: group, signal: signal)
        }
        for identity in live.reversed() where inspector.isRunning(identity) {
            signaler.signal(processIdentifier: identity.processIdentifier, signal: signal)
        }
    }

    private static func unique(_ identities: [SudoProcessIdentity]) -> [SudoProcessIdentity] {
        var seen: Set<Int32> = []
        return identities.filter { seen.insert($0.processIdentifier).inserted }
    }
}
