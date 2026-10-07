/// Caps concurrent files channels per device, so one phone cannot pin
/// unbounded descriptors and hashing work in the app process.
actor FilesChannelLimiter {
    let limit: Int
    private var open: [String: Int] = [:]

    init(limit: Int) {
        self.limit = limit
    }

    func acquire(_ install: String) -> Bool {
        guard open[install, default: 0] < limit else { return false }
        open[install, default: 0] += 1
        return true
    }

    func release(_ install: String) {
        open[install] = max(0, open[install, default: 0] - 1)
    }
}
