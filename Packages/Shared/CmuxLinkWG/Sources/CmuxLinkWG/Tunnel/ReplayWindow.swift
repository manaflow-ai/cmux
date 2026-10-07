/// The receive counter window of one keypair: 2048 counters behind the
/// greatest accepted one (RFC 6479 style bitmap).
struct ReplayWindow {
    static let size: UInt64 = 2048

    private var greatest: UInt64?
    private var bits = [UInt64](repeating: 0, count: Int(ReplayWindow.size / 64))

    /// A cheap check before decryption; `accept` must follow a successful open.
    func canAccept(_ counter: UInt64) -> Bool {
        guard let greatest else { return true }
        if counter > greatest { return true }
        if greatest - counter >= Self.size { return false }
        return !isSet(counter)
    }

    mutating func accept(_ counter: UInt64) -> Bool {
        guard canAccept(counter) else { return false }
        if let greatest, counter > greatest {
            let distance = counter - greatest
            if distance >= Self.size {
                for index in bits.indices { bits[index] = 0 }
            } else {
                var value = greatest &+ 1
                while value < counter {
                    clear(value)
                    value &+= 1
                }
            }
        }
        if greatest.map({ counter > $0 }) ?? true { greatest = counter }
        set(counter)
        return true
    }

    private func isSet(_ counter: UInt64) -> Bool {
        let slot = counter % Self.size
        return bits[Int(slot / 64)] & (1 << (slot % 64)) != 0
    }

    private mutating func set(_ counter: UInt64) {
        let slot = counter % Self.size
        bits[Int(slot / 64)] |= 1 << (slot % 64)
    }

    private mutating func clear(_ counter: UInt64) {
        let slot = counter % Self.size
        bits[Int(slot / 64)] &= ~(1 << (slot % 64))
    }
}
