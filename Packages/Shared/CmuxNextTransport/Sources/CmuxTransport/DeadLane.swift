/// What lane() returns on a dead connection: immediate EOF, fail-fast sends
/// (contract 7.2). Never a hang.
struct DeadLane: TransportLane {
    let name: String

    func send(_ frame: Frame) async throws {
        throw TransportError.pipeClosed
    }

    func receive() async -> Frame? { nil }

    var backpressureStalls: Int { 0 }
}
