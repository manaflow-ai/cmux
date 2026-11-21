import Foundation

/// The Add Machine card's checklist (plans/cmux-next/add-machine-DESIGN.md): the steps of one `cmux-tui acp host
/// enroll|doctor --json` run, filled in from its JSON lines as they arrive. Before a step's line arrives it is pending;
/// the first pending step after the last finished one is running. A step this build does not know joins after the last
/// line that arrived, by its raw name.
nonisolated struct AddMachineChecklist: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case pending, running
        case done(HostStepState)
    }

    struct Row: Equatable, Sendable {
        var step: HostStep
        var status: Status
        var detail = ""
        var fix: String?
    }

    private(set) var rows: [Row]
    /// Whether the app installs its own cmux-tui build now (the install row runs again).
    private(set) var installing = false

    /// Every step of `steps` pending: the card before a run starts.
    init(_ steps: [HostStep] = HostStep.known) {
        rows = steps.map { Row(step: $0, status: .pending) }
    }

    /// The checklist of a run, folded from its events in order.
    init(events: [AddMachineRuns.Event]) {
        self.init()
        for event in events {
            switch event {
            case let .start(joined): start(joined ? [] : HostStep.known)
            case let .line(line):
                switch HostLine.parse(line) {
                case let .step(result)?: apply(result)
                case let .report(report)?: finish(report)
                case nil: break
                }
            case .install:
                installing = true
                run(.install)
            case .installEnd: installing = false
            case let .stop(detail):
                installing = false
                stop(detail)
            }
        }
    }

    /// A run starts: every row of `steps` pending, the first running.
    mutating func start(_ steps: [HostStep]) {
        rows = steps.map { Row(step: $0, status: .pending) }
        markNextRunning()
    }

    /// One step line arrived.
    mutating func apply(_ result: HostStepResult) {
        let row = Row(step: result.step, status: .done(result.state), detail: result.detail, fix: result.fix)
        for index in rows.indices where rows[index].status == .running { rows[index].status = .pending }
        if let index = rows.firstIndex(where: { $0.step == result.step }) {
            rows[index] = row
        } else {
            rows.insert(row, at: lastDone + 1)
        }
        markNextRunning()
    }

    /// The report line: its steps are the truth, and a step it does not name was not run.
    mutating func finish(_ report: HostReport) {
        for step in report.steps { apply(step) }
        for index in rows.indices where !rows[index].isDone { rows[index].status = .done(.skip) }
    }

    /// The run stopped without a report: the running step fails with `detail`, the rest stay pending.
    mutating func stop(_ detail: String) {
        var index = rows.firstIndex { $0.status == .running } ?? rows.firstIndex { $0.status == .pending }
        // With no row left open (a joined machine's check starts with none), a Check it row carries why.
        if index == nil {
            rows.append(Row(step: HostStep(rawValue: "check"), status: .pending))
            index = rows.count - 1
        }
        guard let index else { return }
        rows[index] = Row(step: rows[index].step, status: .done(.fail), detail: detail)
    }

    /// Shows `step` as running again (the app installs its own cmux-tui build).
    mutating func run(_ step: HostStep) {
        guard let index = rows.firstIndex(where: { $0.step == step }) else { return }
        for each in rows.indices where rows[each].status == .running { rows[each].status = .pending }
        rows[index] = Row(step: step, status: .running)
    }

    /// The first failed row: the one a failed card shows with its fix.
    var failing: Row? { rows.first { $0.status == .done(.fail) } }

    private var lastDone: Int { rows.lastIndex(where: \.isDone) ?? -1 }

    private mutating func markNextRunning() {
        guard let index = rows.indices.dropFirst(lastDone + 1).first(where: { rows[$0].status == .pending }) else { return }
        rows[index].status = .running
    }

    /// The checklist as plain text: host, name and one line per step with its fix (Copy Details).
    func details(host: String, name: String) -> String {
        var lines = ["host: \(host)", "name: \(name)"]
        for row in rows {
            let state = switch row.status {
            case .pending: "pending"
            case .running: "running"
            case let .done(state): state.rawValue
            }
            var line = "\(row.step.rawValue): \(state)"
            if !row.detail.isEmpty { line += " - \(row.detail)" }
            if let fix = row.fix { line += " (fix: \(fix))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

extension AddMachineChecklist.Row {
    nonisolated var isDone: Bool { if case .done = status { true } else { false } }
}
