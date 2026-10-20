import Foundation

struct SimulatorWorkerConnection: Sendable {
    let processIdentifier: Int32?
    let messages: AsyncStream<Data>
    let send: @Sendable (Data) throws -> Void
    let closeInput: @Sendable () -> Void
    let terminate: @Sendable () -> Void
    let terminalFailure: @Sendable () -> SimulatorFailure?
}
