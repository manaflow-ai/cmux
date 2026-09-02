import CmuxIrxTransport
import Foundation

/// Scheduling and ownership guards for the irx host recovery state machine.
/// Kept separate from the transition handlers so the lifecycle file remains
/// below the tracked Swift source-size limit.
@MainActor
extension MobileHostIrxRuntime {
    /// Restarts only credential renewal while a still-healthy endpoint keeps
    /// serving existing sessions after a terminal mint response.
    @discardableResult
    func scheduleAutopilotRecovery(
        failure: IrxBrokerFailure,
        accountID: String,
        token: UUID
    ) -> Bool {
        guard autopilotRecoveryTask == nil else { return true }
        guard terminalRecoveryCount < 3 else {
            Self.journal.record(
                "host-runtime", "autopilot-recovery-exhausted",
                failure.journalAttributes
            )
            return false
        }
        let delay = activationRetryPolicy.retrySchedule.delay(
            failureCount: terminalRecoveryCount,
            retryAfterSeconds: nil,
            jitterUnitInterval: 0
        )
        terminalRecoveryCount += 1
        let clock = activationRetryClock
        let deadline = clock.now().addingTimeInterval(delay)
        var attributes = failure.journalAttributes
        attributes["delay_s"] = String(Int(delay.rounded()))
        Self.journal.record("host-runtime", "autopilot-retry-scheduled", attributes)
        let retryID = UUID()
        autopilotRecoveryID = retryID
        autopilotRecoveryTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.autopilotRecoveryID == retryID {
                    self.autopilotRecoveryTask = nil
                    self.autopilotRecoveryID = nil
                }
            }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.generationToken == token,
                  self.activeAccountID == accountID else { return }
            await self.autopilot?.kick()
        }
        return true
    }

    /// A level-triggered activation guard. Every continuation that can create
    /// or publish a resource checks the current desired owner, feature flag,
    /// activity generation, and task cancellation state.
    func isActivationCurrent(
        accountID: String,
        activityGeneration: UInt64,
        token: UUID
    ) -> Bool {
        !Task.isCancelled
            && desiredActive
            && Self.isEnabled
            && activeAccountID == accountID
            && desiredActivityGeneration == activityGeneration
            && generationToken == token
    }

    /// Gives non-auth terminal failures a few bounded recovery probes. Once
    /// those probes are exhausted the runtime stays explicitly failed until an
    /// account transition, policy re-enable, or Settings refresh resets it.
    func scheduleFailedActivationRecovery(
        failure: IrxBrokerFailure,
        accountID: String
    ) {
        guard activeAccountID == accountID,
              desiredActive,
              Self.isEnabled,
              activationRetryTask == nil else { return }
        guard terminalRecoveryCount < 3 else {
            Self.journal.record(
                "host-runtime", "activation-recovery-exhausted",
                failure.journalAttributes
            )
            return
        }
        let delay = activationRetryPolicy.retrySchedule.delay(
            failureCount: terminalRecoveryCount,
            retryAfterSeconds: nil,
            jitterUnitInterval: 0
        )
        terminalRecoveryCount += 1
        let token = generationToken
        let activityGeneration = desiredActivityGeneration
        let clock = activationRetryClock
        let deadline = clock.now().addingTimeInterval(delay)
        var attributes = failure.journalAttributes
        attributes["delay_s"] = String(Int(delay.rounded()))
        attributes["state"] = IrxHostActivationState.failed.rawValue
        Self.journal.record("host-runtime", "activation-retry-scheduled", attributes)
        let retryID = UUID()
        activationRetryID = retryID
        activationRetryTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.activationRetryID == retryID {
                    self.activationRetryTask = nil
                    self.activationRetryID = nil
                }
            }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  self.isActivationCurrent(
                      accountID: accountID,
                      activityGeneration: activityGeneration,
                      token: token
                  ) else { return }
            self.setActivationState(.activating)
            self.startActivation(accountID: accountID)
        }
    }
}
