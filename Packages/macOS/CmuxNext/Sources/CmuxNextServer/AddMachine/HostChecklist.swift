/// The Add Machine card's checklist: the nine steps, filled in live from the CLI's JSON lines.
/// Before a step's line arrives it is pending; the first pending step after the last finished one
/// is running. A step this build does not know joins after the last line that arrived, by its
/// raw name.
public nonisolated struct HostChecklist: Equatable, Sendable {
    public nonisolated enum Status: Equatable, Sendable {
        case pending
        case running
        case done(HostStepState)
    }

    public nonisolated struct Row: Equatable, Sendable, Identifiable {
        public var step: HostStep
        public var status: Status
        public var detail: String
        public var fix: String?

        public var id: HostStep { step }

        public init(step: HostStep, status: Status, detail: String = "", fix: String? = nil) {
            self.step = step
            self.status = status
            self.detail = detail
            self.fix = fix
        }
    }

    public private(set) var rows: [Row]

    /// Every step of `steps` pending: the card before a run starts. By default the enroll and
    /// doctor steps; a joined machine's check starts empty and lists the steps its run sends.
    public init(steps: [HostStep] = HostStep.known) {
        rows = steps.map { Row(step: $0, status: .pending) }
    }

    /// The rows of a finished report (a doctor run shown again).
    public init(report: HostReport) {
        self.init()
        finish(report)
    }

    /// A run starts: every row of `steps` pending, the first running.
    public mutating func start(steps: [HostStep] = HostStep.known) {
        self = HostChecklist(steps: steps)
        markNextRunning()
    }

    /// One step line arrived.
    public mutating func apply(_ result: HostStepResult) {
        let row = Row(step: result.step, status: .done(result.state), detail: result.detail, fix: result.fix)
        for index in rows.indices where rows[index].status == .running { rows[index].status = .pending }
        if let index = rows.firstIndex(where: { $0.step == result.step }) {
            rows[index] = row
        } else {
            let after = rows.lastIndex { if case .done = $0.status { true } else { false } }
            rows.insert(row, at: after.map { $0 + 1 } ?? 0)
        }
        markNextRunning()
    }

    /// The report line: its steps are the truth, and a step it does not name was not run.
    public mutating func finish(_ report: HostReport) {
        for step in report.steps { apply(step) }
        for index in rows.indices {
            switch rows[index].status {
            case .pending, .running: rows[index].status = .done(.skip)
            case .done: break
            }
        }
    }

    /// The run stopped without a report (the CLI could not start, crashed or was cancelled): the
    /// running step fails with `detail`, the rest stay pending.
    public mutating func stop(_ detail: String) {
        // With no row left open (a joined machine's check starts with none, and its rows may all
        // be done before the run fails), a Check it row carries why it stopped.
        let open = rows.firstIndex(where: { $0.status == .running }) ?? rows.firstIndex(where: { $0.status == .pending })
        let index = open ?? {
            rows.append(Row(step: HostStep(rawValue: "check"), status: .pending))
            return rows.count - 1
        }()
        rows[index].status = .done(.fail)
        rows[index].detail = detail
        rows[index].fix = nil
    }

    /// Shows `step` as running again (the app installs its own cmux-tui build).
    public mutating func run(_ step: HostStep) {
        guard let index = rows.firstIndex(where: { $0.step == step }) else { return }
        for other in rows.indices where rows[other].status == .running { rows[other].status = .pending }
        rows[index].status = .running
        rows[index].detail = ""
        rows[index].fix = nil
    }

    public func row(_ step: HostStep) -> Row? {
        rows.first { $0.step == step }
    }

    /// The first failed row: the one a failed card keeps open with its fix.
    public var failing: Row? {
        rows.first { $0.status == .done(.fail) }
    }

    /// A run in one line: steps finished, of how many, and the one running now (nil when none is).
    public nonisolated struct Summary: Equatable, Sendable {
        public var done: Int
        public var total: Int
        public var current: HostStep?
    }

    public var summary: Summary {
        let done = rows.count { if case .done = $0.status { true } else { false } }
        return Summary(done: done, total: rows.count, current: rows.first { $0.status == .running }?.step)
    }

    /// A step failed or warned: the card opens the whole checklist with its fixes. A skip or a fix
    /// the run made itself needs nobody.
    public var needsPerson: Bool {
        rows.contains { $0.status == .done(.fail) || $0.status == .done(.warn) }
    }

    private mutating func markNextRunning() {
        let start = (rows.lastIndex { if case .done = $0.status { true } else { false } }).map { $0 + 1 } ?? 0
        guard let next = rows[start...].firstIndex(where: { $0.status == .pending }) else { return }
        rows[next].status = .running
    }
}
