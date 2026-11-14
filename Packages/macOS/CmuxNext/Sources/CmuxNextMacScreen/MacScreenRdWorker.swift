import Foundation

/// The platform worker boundary, injectable without starting a process or capturing a screen.
/// Carrier decisions remain typed Rust output; the adapter only forwards them.
nonisolated protocol MacScreenRdWorker: AnyObject, Sendable {
    var lines: AsyncStream<MacScreenRdMessage> { get }
    var started: Bool { get }
    var stderrTail: String { get }
    func start(_ role: MacScreenRdProcess.Role) throws
    func send<Value: Encodable>(_ value: Value)
    func stop()
}
