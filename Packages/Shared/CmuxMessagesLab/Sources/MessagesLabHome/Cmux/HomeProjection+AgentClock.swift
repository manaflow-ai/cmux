import CmuxHomeCore
import Foundation

/// A working agent's pill says how long it has worked ("12m", HomeAgentFoldRowProvider `time`), so its row is
/// drawn again at the minute its time changes, and only then: one wait for the soonest such minute across the
/// transcript's agents rows, none while no agent works. Each wake re-draws only the agents rows whose part
/// changed (`.setCustomPart`), never the transcript (user 2026-11-19: "would be useful to see how long it has
/// been running for").
extension HomeProjection {
    /// Waits for the next minute a shown working agent's time changes, then draws those rows again.
    func scheduleAgentClock(now: Date = Date()) {
        let next = stopped ? nil : shown.compactMap { item -> TimeInterval? in
            guard let row = item.agentMessage, HomeAgentFoldRowProvider.ticks(row) else { return nil }
            return HomeAgentFoldRowProvider.nextChange(row, now: now)
        }.min()
        let due = next.map { now.addingTimeInterval($0) }
        // Every store change refreshes: a wait for the same minute stays, so a streaming reply makes no new task.
        if let due, agentClock != nil, let held = agentClockDue, abs(held.timeIntervalSince(due)) < 0.5 { return }
        agentClock?.cancel()
        agentClock = nil
        agentClockDue = due
        guard let next else { return }
        // A display clock's deadline (the next whole minute of a working agent), not a poll: it is cancelled on
        // every refresh and on stop, and re-armed from the rows then shown.
        agentClock = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(next + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.agentClock = nil
            self.redrawAgentTimes()
            self.scheduleAgentClock()
        }
    }

    /// The agents rows whose pill times moved draw again with the new times, in place.
    func redrawAgentTimes(now: Date = Date()) {
        guard !stopped, let store = controller.store else { return }
        for item in shown {
            guard let row = item.agentMessage, HomeAgentFoldRowProvider.ticks(row),
                  case let .custom(want)? = HomeAgentFoldRowProvider.part(row, now: now) else { continue }
            let id = HomeMapping.id(item, aliases: aliases)
            guard let message = store.state.message(id), case let .custom(have)? = message.parts[checked: 0],
                  have.kind == want.kind, have != want else { continue }
            controller.dispatch(.setCustomPart(id, 0, want))
        }
    }
}
