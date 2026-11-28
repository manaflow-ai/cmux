#if DEBUG || CMUX_BENCH_HOOKS
/// What one ScreenCaptureKit stream gave, buffer by buffer: the reply's `screen_stream`, numbers and status letters
/// only. A frame of the display with no row in a frame strip has one of three causes, and these counts tell them
/// apart: a buffer that made no row (`no_row`: another status than complete or idle, or a picture that did not
/// copy), a row whose time is the handler's own and not the display's (`own_time_rows`), or no buffer at all.
nonisolated struct StreamTally: Sendable {
    /// Why a buffer made no row, where that is not its status's raw number.
    static let noStatus = -1, noPicture = -2, idleBeforeAPicture = -3

    /// Where a row's time comes from: the buffer's display time (`age` ms before the handler ran), or the handler's
    /// own time (the buffer has no display time, or one later than the handler's).
    nonisolated enum Time: Sendable {
        case display(age: Double)
        case missing
        case later

        /// True for the handler's own time.
        var isOwn: Bool {
            switch self {
            case .display: false
            case .missing, .later: true
            }
        }
    }

    private var rowStatus = ""
    private var rowTimes: [Double] = []
    private var ownTimeRows: [Int] = []
    private var noRows: [(at: Double, why: Int, own: Bool)] = []
    private var noRowCounts: [Int: Int] = [:]
    private var complete = 0
    private var idle = 0
    private var noDisplayTime = 0
    private var displayTimeLater = 0
    private var lagMax = 0.0
    private var lagSum = 0.0
    private var lagCount = 0
    private var workMax = 0.0
    private var workSum = 0.0

    /// A buffer that made the row `index` (its place in the frames, which is the number of its file), `at` ms after
    /// the start. `status`: `c` a complete buffer's picture, `i` an idle buffer's repeat of the last picture.
    /// `work`: the handler's ms for it.
    mutating func row(_ status: Character, index: Int, at: Double, time: Time, work: Double) {
        rowStatus.append(status)
        rowTimes.append(at)
        if status == "c" {
            complete += 1
            workMax = max(workMax, work)
            workSum += work
        } else {
            idle += 1
        }
        switch time {
        case let .display(age):
            lagMax = max(lagMax, age)
            lagSum += age
            lagCount += 1
        case .missing:
            noDisplayTime += 1
            ownTimeRows.append(index)
        case .later:
            displayTimeLater += 1
            ownTimeRows.append(index)
        }
    }

    /// A buffer that made no row, `at` ms after the start. `why`: its status's raw number, or one of the three above.
    /// `own`: `at` is the handler's own time, not the buffer's display time (the buffer's frame of the display is
    /// then at `at` or before it). The first 256 keep their time and `own`.
    mutating func noRow(at: Double, why: Int, own: Bool) {
        noRowCounts[why, default: 0] += 1
        if noRows.count < 256 { noRows.append((at, why, own)) }
    }

    /// The reply's `screen_stream`. `sentAt`: when the key went in, ms after the start; `no_row` and `row_ms` (each
    /// row's time, in tenths of a ms where the row's own `ms` is a whole one) count from it. A `no_row` entry: the
    /// time, why, and 1 for the handler's own time or 0 for the display's.
    func fields(sentAt: Double) -> [String: any Sendable] {
        func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        let noStatus = noRowCounts[Self.noStatus] ?? 0
        let noPicture = noRowCounts[Self.noPicture] ?? 0
        let idleBeforeAPicture = noRowCounts[Self.idleBeforeAPicture] ?? 0
        var otherStatus: [String: Int] = [:]
        for (why, count) in noRowCounts where why >= 0 { otherStatus[String(why)] = count }
        let buffers = rowStatus.count + noRowCounts.values.reduce(0, +)
        let noRowTimes: [[Double]] = noRows.map { [tenth($0.at - sentAt), Double($0.why), $0.own ? 1 : 0] }
        let rowMs: [Double] = rowTimes.map { tenth($0 - sentAt) }
        let lagMean = lagCount > 0 ? lagSum / Double(lagCount) : 0
        let workMean = complete > 0 ? workSum / Double(complete) : 0
        var fields: [String: any Sendable] = ["buffers": buffers, "rows": rowStatus.count, "row_status": rowStatus]
        fields["complete"] = complete + noPicture
        fields["idle"] = idle + idleBeforeAPicture
        fields["other_status"] = otherStatus
        fields["no_status"] = noStatus
        fields["no_picture"] = noPicture
        fields["idle_before_a_picture"] = idleBeforeAPicture
        fields["own_time_rows"] = ownTimeRows
        fields["no_display_time"] = noDisplayTime
        fields["display_time_later"] = displayTimeLater
        fields["no_row"] = noRowTimes
        fields["row_ms"] = rowMs
        fields["lag_ms_max"] = tenth(lagMax)
        fields["lag_ms_mean"] = tenth(lagMean)
        fields["work_ms_max"] = tenth(workMax)
        fields["work_ms_mean"] = tenth(workMean)
        return fields
    }
}
#endif
