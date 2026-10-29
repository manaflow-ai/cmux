/// A `debug.input` section whose producer lives in a package this one does not import (the browser
/// engine's ``DebugInputSection/chromium``): the App passes its read and reset. Both run
/// on the control request's task; a producer with main-thread state hops there itself.
///
/// ```swift
/// DebugInputSectionSource(section: .chromium, read: { await reader.read() }, reset: { await reader.reset() })
/// ```
public nonisolated struct DebugInputSectionSource<Value: Encodable & Sendable>: DebugInputSource {
    public let section: DebugInputSection
    private let readValue: @Sendable () async -> Value
    private let resetValue: @Sendable () async -> Void

    /// - Parameters:
    ///   - section: The section the producer fills.
    ///   - read: The section now.
    ///   - reset: Starts the producer's counters over.
    public init(section: DebugInputSection, read: @escaping @Sendable () async -> Value, reset: @escaping @Sendable () async -> Void) {
        self.section = section
        readValue = read
        resetValue = reset
    }

    public func read() async -> Value {
        await readValue()
    }

    public func reset() async {
        await resetValue()
    }
}
