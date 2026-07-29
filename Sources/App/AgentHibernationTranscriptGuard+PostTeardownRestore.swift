import Darwin
import Foundation

extension AgentHibernationTranscriptGuard {
    enum PostTeardownSnapshotDisposal: Sendable {
        /// Normal hibernation monitor: a healthy live transcript makes the
        /// snapshot redundant, so it is deleted on completion.
        case deleteWhenSafe
        /// Forfeit monitor for a snapshot whose live path provably diverged:
        /// "live has turns" no longer implies "live contains the snapshot", so
        /// on completion an unrestored snapshot moves to the session's retained
        /// recovery slot instead of being deleted.
        case retainForRecovery(sessionId: String?)
    }

    static func runPostTeardownRestoreChecks(
        snapshot: TeardownTranscriptSnapshot,
        processIDs: Set<Int>,
        initialRetryDelaysNanoseconds: [UInt64] = [0, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000],
        backstopDelaysSeconds: [UInt64] = Self.restoreCheckDelaysSeconds,
        clock: ContinuousClock = ContinuousClock(),
        fileManager: FileManager = .default,
        snapshotDisposal: PostTeardownSnapshotDisposal = .deleteWhenSafe,
        shouldContinue: @Sendable () async -> Bool = { true },
        shouldRestoreOnCancellation: @Sendable () async -> Bool = { true }
    ) async {
        var canDeleteSnapshot = false
        var retainSnapshot = false
        var restoredSnapshot = false

        func markSnapshotDeletableIfSafe() {
            let restored = restoreIfClobbered(snapshot, fileManager: fileManager)
            let safe = transcriptHasConversationTurns(atPath: snapshot.transcriptPath, fileManager: fileManager)
            restoredSnapshot = restoredSnapshot || restored
            canDeleteSnapshot = restored || safe
        }

        func restoreBeforeStoppedReturn() async {
            retainSnapshot = true
            guard await shouldRestoreOnCancellation() else { return }
            markSnapshotDeletableIfSafe()
        }

        func stopIfNoLongerCurrent() async -> Bool {
            guard await shouldContinue() else {
                await restoreBeforeStoppedReturn()
                return true
            }
            return false
        }

        defer {
            if !retainSnapshot, !Task.isCancelled, canDeleteSnapshot {
                switch snapshotDisposal {
                case .deleteWhenSafe:
                    try? fileManager.removeItem(atPath: snapshot.snapshotPath)
                case .retainForRecovery(let sessionId):
                    if restoredSnapshot {
                        // The snapshot's content was committed back to the live
                        // path, so the copy is genuinely redundant.
                        try? fileManager.removeItem(atPath: snapshot.snapshotPath)
                    } else {
                        retainSnapshotForRecovery(snapshot, sessionId: sessionId, fileManager: fileManager)
                    }
                }
            }
        }

        if !processIDs.isEmpty {
            let deadline = clock.now.advanced(by: .seconds(30))
            while clock.now < deadline {
                let anyAlive = processIDs.contains { pid in
                    pid > 0 && pid <= Int(Int32.max) && kill(pid_t(pid), 0) == 0
                }
                if !anyAlive { break }
                // Bounded process-exit grace period before transcript restore checks; controller state cancels this task.
                do {
                    try await clock.sleep(for: .milliseconds(250))
                } catch {
                    await restoreBeforeStoppedReturn()
                    return
                }
                if Task.isCancelled {
                    await restoreBeforeStoppedReturn()
                    return
                }
                if await stopIfNoLongerCurrent() { return }
            }
        }

        for delayNanoseconds in initialRetryDelaysNanoseconds {
            if delayNanoseconds > 0 {
                // Bounded Claude transcript-rewrite check window; controller state cancels this task.
                do {
                    try await clock.sleep(for: .nanoseconds(Int64(clamping: delayNanoseconds)))
                } catch {
                    await restoreBeforeStoppedReturn()
                    return
                }
            }
            if Task.isCancelled {
                await restoreBeforeStoppedReturn()
                return
            }
            if await stopIfNoLongerCurrent() { return }
            markSnapshotDeletableIfSafe()
        }

        for delaySeconds in backstopDelaysSeconds {
            // Bounded delayed restore backstop; controller state cancels this task.
            do {
                try await clock.sleep(for: .seconds(Int64(clamping: delaySeconds)))
            } catch {
                await restoreBeforeStoppedReturn()
                return
            }
            if Task.isCancelled {
                await restoreBeforeStoppedReturn()
                return
            }
            if await stopIfNoLongerCurrent() { return }
            markSnapshotDeletableIfSafe()
        }
    }
}
