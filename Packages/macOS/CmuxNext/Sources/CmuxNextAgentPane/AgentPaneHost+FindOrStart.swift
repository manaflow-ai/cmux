import Darwin
import Foundation
import os

extension AcpmuxHost {
    /// What a lookup does besides finding or starting the daemon; all of it only for a daemon
    /// this app owns.
    struct Upkeep: Sendable {
        /// Counts status calls that miss their deadline and restarts a daemon that stopped answering.
        var watch: AcpmuxUnresponsiveWatch?
        /// Hands a stale daemon off at a quiet moment (nil: as before the toggle).
        var quietWait: AcpmuxQuietHandoff?
        /// Called with a stale daemon's pid that was kept because it is busy.
        var onWaiting: (@Sendable (Int32) -> Void)?
    }

    /// A shutdown removes `daemon.pid`; kill -9 or a crash leaves it naming a dead process,
    /// and a daemon nobody reaped leaves a zombie, which `kill(pid, 0)` still reports alive.
    nonisolated static func crashed(_ home: URL) -> Bool {
        guard let text = try? String(contentsOf: home.appendingPathComponent("daemon.pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return !agentPaneProcessIsRunning(pid)
    }

    /// Logs `cause` to the daemon's log and makes the error the pane shows.
    static func failure(_ environment: AcpmuxEnvironment, _ cause: AcpmuxFailureCause, detail: String) -> AgentPaneHostError {
        AcpmuxFailureLog(logPath: environment.logPath).record(cause, detail: detail)
        return .daemonFailed(logPath: environment.logPath, cause: cause)
    }

    static func findOrStart(_ environment: AcpmuxEnvironment, startsDaemon: Bool, owned: Bool,
                            heal: (@Sendable (Int32) async -> Bool)?, upkeep: Upkeep = Upkeep()) async throws -> AcpmuxWebEndpoint {
        // cmux NEXT adopts its old acpmux home before it asks or starts a daemon (cx-is1kf.9).
        await AcpmuxEnvironment.adoptBuildHomes()
        var answered = false
        // This lookup stopped or restarted the daemon: the next one must prove healthy.
        var replacing = false
        do {
            let status = try await AcpmuxStatusClient.status(socketPath: environment.socketPath)
            answered = true
            upkeep.watch?.answered(home: environment.home.standardizedFileURL.path)
            // A daemon of another acpmux home answers on this socket: it is another app's or
            // tag's. Never hand it off, stop it or use it.
            guard status.serves(home: environment.home) else {
                logger.error("acpmux socket=\(environment.socketPath, privacy: .public) serves home=\(status.home ?? "", privacy: .public), not this app's home=\(environment.home.path, privacy: .public)")
                AcpmuxFailureLog(logPath: environment.logPath).record(.foreignHome, detail: "home \(status.home ?? "?")")
                let holder = status.pid.flatMap(AcpmuxVersionHandoff.executablePath(pid:)).map(AcpmuxServerPeer.holderName(executablePath:))
                throw AgentPaneHostError.daemonRefused(holder: holder, socketPath: environment.socketPath,
                                                       reason: "it serves the acpmux home \(status.home ?? ""), not \(environment.home.path)")
            }
            // After an update the daemon may be the previous build's: a daemon on this app's home
            // is handed off at a daemon start and at every reconnect (its agents keep running under
            // their hosts) and ours starts below. One that is busy is handed off when quiet. At a
            // daemon start, a daemon no cmux install runs (`~/.local/bin/acpmux`) is taken over
            // first (`AcpmuxStrayDaemon`).
            let stray = startsDaemon ? await AcpmuxStrayDaemon.handOffIfStray(status, environment: environment) : false
            let outcome: AcpmuxVersionHandoff.Outcome = if stray {
                .stopped
            } else if owned {
                await AcpmuxVersionHandoff.handOffIfStale(status, environment: environment, quietWait: upkeep.quietWait)
            } else {
                .kept
            }
            if outcome == .waitingForQuiet, let pid = status.pid { upkeep.onWaiting?(pid) }
            replacing = outcome == .stopped
            // Otherwise a reconnect never stops or starts a daemon. It still gives a daemon that
            // restarted this launch's person key (a signed daemon takes it by this app's
            // signature), so the reconnected pane's allows keep working.
            if !replacing && !startsDaemon {
                _ = await AcpmuxPersonKey.enroll(status, environment: environment, mayHandOff: false)
                await AcpmuxComputerUse.enroll(environment)
                do {
                    return try await Self.verifiedEndpoint(environment)
                } catch let refusal as AcpmuxServerPeer.Refusal {
                    // A daemon that only runs an old version an update replaced: its owner
                    // hands it off (its agents are adopted) and starts the bundled one.
                    if let pid = status.pid, AcpmuxVersionHandoff.replaced(pid: pid) {
                        AcpmuxFailureLog(logPath: environment.logPath).record(.replacedBundle, detail: "pid \(pid): \(refusal)")
                        if let heal, await heal(pid) {
                            logger.info("acpmux \(pid) ran a replaced bundle; its owner restarts it")
                            throw AgentPaneHostError.daemonRestarting
                        }
                        throw Self.refused(refusal, environment, reason: AcpmuxFailureCause.replacedBundle.logText)
                    }
                    throw Self.refused(refusal, environment)
                }
            }
            // For this launch's person key (`AcpmuxPersonKey`): a daemon that cannot take the
            // key is handed off and ours starts with it.
            if !replacing {
                replacing = await AcpmuxPersonKey.enroll(status, environment: environment)
                guard replacing else {
                    await AcpmuxComputerUse.enroll(environment)
                    return try await Self.verifiedEndpoint(environment)
                }
            }
        } catch AcpmuxStatusClient.Failure.unreachable {
            logger.info("acpmux status unreachable socket=\(environment.socketPath, privacy: .public) startsDaemon=\(startsDaemon, privacy: .public)")
            // Nothing listens on the socket: start a daemon below, unless
            // the user stopped it. A reconnect starts one only after a crash
            // (cx-6bgzj); the new daemon adopts the agents still running.
            guard startsDaemon || owned && crashed(environment.home) else {
                throw owned ? AgentPaneHostError.daemonStopped : AgentPaneHostError.chiefStopped
            }
        } catch AcpmuxStatusClient.Failure.noWebSocket {
            logger.error("acpmux status returned no websocket socket=\(environment.socketPath, privacy: .public)")
            throw failure(environment, .noWebSocket, detail: environment.socketPath)
        } catch is AgentPaneDeadlineExceeded {
            logger.error("acpmux status timed out socket=\(environment.socketPath, privacy: .public)")
            // A daemon that stays alive but stopped answering holds its lock: no new one could
            // start. Once it is restarted, start one below; it adopts the agent hosts.
            guard !answered, let watch = upkeep.watch, await watch.restartIfStuck(environment) else {
                throw AgentPaneHostError.timedOut
            }
            replacing = true
        } catch let error as AgentPaneHostError {
            throw error
        } catch let refusal as AcpmuxServerPeer.Refusal {
            throw Self.refused(refusal, environment)
        } catch {
            logger.error("acpmux status failed error=\(String(describing: error), privacy: .public)")
            throw failure(environment, .other, detail: String(describing: error))
        }
        return try await launch(environment, replacing: replacing)
    }

    /// Starts the daemon. After a handoff or a restart (`replacing`), the new daemon must answer
    /// `_acpmux/status` from this home with the bundled build (``healthProblem(_:)``): a start that
    /// does not is tried once more, then the chat shows that acpmux did not start and the
    /// daemon's log says why (`unhealthyAfterRestart`). There is no rollback to the previous
    /// daemon: the app keeps no acpmux outside its bundle, and the update replaced the bundle,
    /// so that notice and the page's next retry are the fallback. Every session's state stays on
    /// disk either way (the handoff never sends `endAgents`).
    static func launch(_ environment: AcpmuxEnvironment, replacing: Bool) async throws -> AcpmuxWebEndpoint {
        guard replacing else { return try await startDaemon(environment) }
        var problem = ""
        for attempt in 1...2 {
            do {
                let endpoint = try await startDaemon(environment)
                guard let found = await healthProblem(environment) else { return endpoint }
                problem = found
            } catch {
                problem = String(describing: error)
            }
            logger.error("acpmux start \(attempt, privacy: .public) after a handoff is not healthy: \(problem, privacy: .public)")
        }
        throw failure(environment, .unhealthyAfterRestart, detail: problem)
    }

    /// Why the daemon on `environment`'s socket is not this app's healthy one, nil when it answers
    /// `_acpmux/status` from this home with the bundled build (any build when that is unknown).
    static func healthProblem(_ environment: AcpmuxEnvironment) async -> String? {
        let bundled = await AcpmuxVersionHandoff.bundledBuild(environment)
        do {
            let status = try await AcpmuxStatusClient.status(socketPath: environment.socketPath, deadline: .seconds(5))
            guard status.serves(home: environment.home) else { return "it serves the acpmux home \(status.home ?? "?")" }
            if let bundled, status.build != bundled { return "it runs build \(status.build ?? "?"), not \(bundled)" }
            return nil
        } catch {
            return "it did not answer: \(error)"
        }
    }

    static func startDaemon(_ environment: AcpmuxEnvironment) async throws -> AcpmuxWebEndpoint {
        do {
            let endpoint = try await AcpmuxDaemonLauncher.launch(environment)
            // A signed daemon ignores the spawn key: it takes the key by this app's signature.
            if let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath) {
                _ = await AcpmuxPersonKey.enroll(status, environment: environment)
                await AcpmuxComputerUse.enroll(environment)
            }
            return endpoint
        } catch AcpmuxDaemonLauncher.Failure.exited {
            logger.error("acpmux launcher exited before ready log=\(environment.logPath, privacy: .public)")
            // Another client may have started the daemon first; the loser
            // exits because the socket is taken. Ask the winner.
            do {
                await AcpmuxComputerUse.enroll(environment)
                return try await Self.verifiedEndpoint(environment)
            } catch let refusal as AcpmuxServerPeer.Refusal {
                throw Self.refused(refusal, environment)
            } catch {
                throw failure(environment, .exited, detail: String(describing: error))
            }
        } catch is AgentPaneDeadlineExceeded {
            logger.error("acpmux launcher timed out log=\(environment.logPath, privacy: .public)")
            throw AgentPaneHostError.timedOut
        } catch {
            logger.error("acpmux launcher failed error=\(String(describing: error), privacy: .public) log=\(environment.logPath, privacy: .public)")
            throw failure(environment, .other, detail: String(describing: error))
        }
    }
}
