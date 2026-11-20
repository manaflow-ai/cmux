public import CmuxNextAgentPane
public import CmuxUpdater
import Foundation

/// Reads agent activity only while an update or quit decision needs it.
@MainActor
public final class UpdateAgentActivity {
    private let readCensus: (@MainActor () async -> AcpmuxSessionCensus?)?
    private let now: @MainActor () -> Date
    private var lastCensus: AcpmuxSessionCensus?
    private var refreshedAt: Date?
    private var refreshTask: Task<Void, Never>?

    /// A clear answer expires after two seconds. A blocking answer can live longer because it
    /// cannot authorize installation. Starting a refresh never discards a still-fresh answer.
    public var census: AcpmuxSessionCensus? {
        guard readCensus != nil else { return lastCensus }
        guard let refreshedAt, now().timeIntervalSince(refreshedAt) < refreshInterval + 1 else { return nil }
        return lastCensus
    }

    private var refreshInterval: TimeInterval {
        guard let lastCensus, lastCensus.updateActivityKnown,
              lastCensus.inTurn == 0, !lastCensus.chiefInTurn,
              lastCensus.workingBelow == 0, lastCensus.drafts == 0 else { return 5 }
        return 1
    }

    public convenience init(environment: AcpmuxEnvironment?) {
        if let environment {
            self.init(readCensus: { await AcpmuxQuit.census(environment, deadline: .seconds(1)) })
        } else {
            self.init(readCensus: nil)
        }
    }

    /// Clock and reader seams exercise refresh races without a daemon or wall-clock sleeps.
    init(readCensus: (@MainActor () async -> AcpmuxSessionCensus?)?, now: @escaping @MainActor () -> Date = Date.init) {
        self.readCensus = readCensus
        self.now = now
        self.lastCensus = readCensus == nil ? AcpmuxSessionCensus.parse(["sessions": [[String: Any]]()]) : nil
    }

    /// Adds Home Chief activity to a daemon relaunch snapshot, conservatively holding unknown state.
    public func applying(to blockers: UpdateRelaunchBlockers) -> UpdateRelaunchBlockers {
        guard readCensus != nil else { return blockers }
        refreshIfNeeded()
        var result = blockers
        guard let census else {
            result.daemonStateUnavailable = true
            return result
        }
        if census.chiefInTurn { result.busyAgentCount += 1 }
        return result
    }

    private func refreshIfNeeded() {
        guard let readCensus, refreshTask == nil,
              refreshedAt.map({ now().timeIntervalSince($0) >= refreshInterval }) ?? true else { return }
        refreshTask = Task { [weak self] in
            let census = await readCensus()
            guard !Task.isCancelled, let self else { return }
            self.lastCensus = census
            self.refreshedAt = self.now()
            self.refreshTask = nil
        }
    }
}
