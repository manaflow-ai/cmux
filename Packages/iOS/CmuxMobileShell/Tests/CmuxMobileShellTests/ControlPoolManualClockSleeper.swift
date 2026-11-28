import Foundation

struct ControlPoolManualClockSleeper {
    let id: UUID
    let deadline: ControlPoolManualClockInstant
    let continuation: UnsafeContinuation<Void, any Error>
}
