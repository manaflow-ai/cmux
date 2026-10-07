/// Caps concurrent `tcp.forward` streams per device and per host.
actor TunnelStreamLimiter {
    let perDevice: Int
    let total: Int
    private var open: [String: Int] = [:]
    private var count = 0

    init(perDevice: Int, total: Int) {
        self.perDevice = perDevice
        self.total = total
    }

    func acquire(_ install: String) -> Bool {
        guard count < total, open[install, default: 0] < perDevice else { return false }
        open[install, default: 0] += 1
        count += 1
        return true
    }

    func release(_ install: String) {
        guard let current = open[install], current > 0 else { return }
        open[install] = current == 1 ? nil : current - 1
        count -= 1
    }
}
