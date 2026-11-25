// CmuxNextCompat for the Linux settings exporter (scripts/cmux-next/regenerate-settings-exports-linux.sh): the
// files in compat-sources.txt are linked in as they are; these stand in for the few names the settings model reads
// from files that need Darwin. Nothing here runs: the exporter only reads the settings' declarations.
#if !canImport(AppKit)
@_exported public import Synchronization
public import Foundation

extension Mutex where Value: Copyable {
    public borrowing func load(fileID: StaticString = #fileID, line: UInt = #line) -> Value {
        withLock { value in value }
    }
}

extension FileManager {
    /// The Mac's checked file manager reports a blocking call on the main thread; the exporter has no main thread
    /// to guard, so it is the plain one.
    public static var checked: FileManager { .default }
}

/// The Mac's stream of an observed value's changes; the exporter observes nothing, so it ends at once.
public struct ObservationStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias Failure = Never

    public init(_ emit: @escaping @MainActor @Sendable () -> Element, fileID: StaticString = #fileID, line: UInt = #line) {}

    public func makeAsyncIterator() -> Iterator { Iterator() }

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Failure = Never
        public mutating func next() async -> Element? { nil }
    }
}
#endif
