public import Foundation

/// Clock boundary used by cancellable relay refresh scheduling.
public protocol CmxIrohRelayClock: Sendable {
    func now() -> Date
    func sleep(until deadline: Date) async throws
}

/// Wall-clock to monotonic-delay adapter for production relay refreshes.
public struct CmxIrohSystemRelayClock: CmxIrohRelayClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(until deadline: Date) async throws {
        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else { return }
        try await Task<Never, Never>.sleep(for: .seconds(delay))
    }
}
