public import CmuxNextDaemon
import Foundation
import os

/// One captured Chief control route. The brain owns turn eligibility and reply bookkeeping.
@MainActor
public struct HomeChiefTurnControl {
    public let connection: DaemonConnection?
    public let named: String?
    public let isHosted: Bool
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    public init(connection: DaemonConnection?, named: String?, isHosted: Bool) {
        self.connection = connection
        self.named = named
        self.isHosted = isHosted
    }

    /// `chief.stop` on this Chief's brain; nil when it stopped (or had no
    /// turn), else why not.
    public func stop() async -> HomeChiefEngineError? {
        switch await stopResult() {
        case .success: return nil
        case .failure(let error): return error
        }
    }

    /// The raw `chief.stop` result for the compose button. Keeping the bool
    /// lets Home expose Continue only after the brain accepted the stop.
    public func stopResult() async -> Result<Bool, HomeChiefEngineError> {
        // The Cloud service has no stop for a hosted Chief's turn yet; no server to ask.
        if isHosted { return .failure(.cloudStopUnsupported) }
        guard let connection else { return .failure(.unreachable) }
        do {
            let stopped = try await ChiefControlClient(connection).stopChief(chief: named)
            Self.logger.info("home: chief.stop answered stopped=\(stopped, privacy: .public)")
            return .success(stopped)
        } catch let error as ChiefControlError {
            Self.logger.error("home: chief.stop failed: \(String(describing: error), privacy: .public)")
            return .failure(HomeChiefEngineError(error))
        } catch {
            return .failure(.other(String(describing: error)))
        }
    }

    /// `chief.continue` for the stopped turn in this Chief's conversation.
    /// The result is false when there is no stopped batch or cancellation is
    /// still settling; callers keep the button until the next idle snapshot.
    public func continueTurn() async -> Result<ChiefTurnActionResult, HomeChiefEngineError> {
        if isHosted { return .failure(.cloudStopUnsupported) }
        guard let connection else { return .failure(.unreachable) }
        do throws(ChiefControlError) {
            return .success(try await ChiefControlClient(connection).continueChief(chief: named))
        } catch {
            return .failure(HomeChiefEngineError(error))
        }
    }

    /// `chief.retry {message}` for one committed person message.
    public func retryChief(message: String) async -> Result<ChiefTurnActionResult, HomeChiefEngineError> {
        if isHosted { return .failure(.cloudStopUnsupported) }
        guard let connection else { return .failure(.unreachable) }
        do throws(ChiefControlError) {
            return .success(try await ChiefControlClient(connection).retryChief(message: message, chief: named))
        } catch {
            return .failure(HomeChiefEngineError(error))
        }
    }

    /// `chief.stop {all: true}` on this Chief's brain: what stopped, else why not.
    public func stopAll() async -> Result<ChiefStopAll, HomeChiefEngineError> {
        if isHosted { return .failure(.cloudStopUnsupported) }
        guard let connection else { return .failure(.unreachable) }
        do throws(ChiefControlError) {
            let answer = try await ChiefControlClient(connection).stopAllAgents(chief: named)
            Self.logger.info("home: stop all agents stopped \(answer.subagents.count, privacy: .public) subagent(s)")
            return .success(answer)
        } catch {
            Self.logger.error("home: stop all agents failed: \(String(describing: error), privacy: .public)")
            return .failure(HomeChiefEngineError(error))
        }
    }

    /// `chief.stop {restart: names}`: Restart on the stop-all toast; nil when
    /// every one went on, else why not.
    public func restart(_ names: [String]) async -> HomeChiefEngineError? {
        guard let connection else { return .unreachable }
        do throws(ChiefControlError) {
            let answer = try await ChiefControlClient(connection).restartAgents(names, chief: named)
            guard answer.errors.isEmpty else {
                Self.logger.error("home: restart: \(answer.errors.joined(separator: "; "), privacy: .public)")
                return .other(answer.errors.joined(separator: "; "))
            }
            return nil
        } catch {
            return HomeChiefEngineError(error)
        }
    }
}
