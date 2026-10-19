/// The publication order encoded in a spool record file name.
///
/// Names have the form `<seconds>.<nanoseconds>-<pid>.rec`; other names are
/// not records.
struct AgentHookSpoolRecordName: Comparable {
    let seconds: Int
    let nanoseconds: Int
    let pid: Int

    init?(_ name: String) {
        guard name.hasSuffix(AgentHookSpoolDirectory.recordSuffix) else { return nil }
        let stem = name.dropLast(AgentHookSpoolDirectory.recordSuffix.count)
        let parts = stem.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let pid = Int(parts[1]), pid > 0 else { return nil }
        let time = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard time.count == 2,
              let seconds = Int(time[0]), seconds >= 0,
              let nanoseconds = Int(time[1]), nanoseconds >= 0 else {
            return nil
        }
        self.seconds = seconds
        self.nanoseconds = nanoseconds
        self.pid = pid
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.seconds, lhs.nanoseconds, lhs.pid) < (rhs.seconds, rhs.nanoseconds, rhs.pid)
    }
}
