import Testing
@testable import CmuxNextDesign

/// Stacking several status reports about one target.
struct StatusStackTests {
    func report(_ id: String, _ source: StatusReport.Source, _ state: StatusIndicatorState, at: UInt64 = 0,
                style: StatusIndicatorStyle? = nil) -> StatusReport {
        StatusReport(id: id, source: source, state: state, label: id, style: style, updatedAtMs: at)
    }

    @Test func emptyAndIdleReportsResolveToIdle() {
        #expect(StatusStack.resolve([]) == .idle)
        #expect(StatusStack.resolve([report("a", .agent, .idle)]) == .idle)
    }

    @Test func problemsBeatWorkAndWorkBeatsDone() {
        let summary = StatusStack.resolve([
            report("done", .run, .success),
            report("build", .explicit, .busy),
            report("claude", .agent, .waiting),
            report("deploy", .explicit, .error),
        ])
        #expect(summary.state == .error)
        #expect(summary.reports.map(\.id) == ["deploy", "claude", "build", "done"])
    }

    @Test func knownProgressBeatsIndeterminateWork() {
        let summary = StatusStack.resolve([report("claude", .agent, .busy), report("cargo", .terminalProgress, .busy(progress: 0.4))])
        #expect(summary.state == .busy(progress: 0.4))
        #expect(summary.primary?.id == "cargo")
    }

    @Test func sourceRankBreaksStateTiesThenNewestWins() {
        #expect(StatusStack.resolve([report("cmd", .command, .busy), report("agent", .agent, .busy)]).primary?.id == "agent")
        #expect(StatusStack.resolve([report("old", .explicit, .busy, at: 1), report("new", .explicit, .busy, at: 2)]).primary?.id == "new")
        // Full tie: deterministic by id.
        #expect(StatusStack.resolve([report("b", .run, .busy), report("a", .run, .busy)]).primary?.id == "a")
    }

    @Test func theWinnersStyleHintIsTheSummaryStyle() {
        let summary = StatusStack.resolve([report("a", .explicit, .busy, style: .native), report("b", .command, .busy, style: .dot)])
        #expect(summary.style == .native)
    }

    @Test func rollUpMergesChildrenAndOwnReports() {
        let tab1 = StatusStack.resolve([report("t1", .agent, .busy)])
        let tab2 = StatusStack.resolve([report("t2", .terminalProgress, .busy(progress: 0.9))])
        let workspace = StatusStack.rollUp([tab1, tab2], own: [report("ws", .explicit, .success)])
        #expect(workspace.state == .busy(progress: 0.9))
        #expect(workspace.reports.count == 3)
    }

    @Test func orderIsATotalOrderOverAllCombinations() {
        let states: [StatusIndicatorState] = [.idle, .busy, .busy(progress: 0.5), .paused(progress: nil), .waiting, .error, .success]
        var reports: [StatusReport] = []
        for (i, state) in states.enumerated() {
            for source in StatusReport.Source.allCases {
                reports.append(report("\(i)-\(source.rawValue)", source, state, at: UInt64(i)))
            }
        }
        for a in reports {
            #expect(!StatusStack.precedes(a, a))
            for b in reports where a != b {
                #expect(StatusStack.precedes(a, b) != StatusStack.precedes(b, a))
            }
        }
    }
}
