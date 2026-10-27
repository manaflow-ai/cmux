import CmuxSafeConcurrency

/// A test fake's state behind the portable ``Mutex`` (CmuxSafeConcurrency builds on Linux, where `os`'s
/// `OSAllocatedUnfairLock` does not exist), in a class so closures can capture it.
final class Locked<Value>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: sending Value) {
        mutex = Mutex(value)
    }

    func withLock<Result>(_ body: (inout sending Value) -> sending Result) -> sending Result {
        mutex.withLock(body)
    }
}
