import Foundation
@testable import CmuxControlSocket

// NSLock protects every access to the optional result, which is the only
// mutable state crossing the detached test task boundary.
final class SimulatorResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ControlCallResult?

    func set(_ value: ControlCallResult) { lock.withLock { self.value = value } }
    func get() -> ControlCallResult? { lock.withLock { value } }
}
