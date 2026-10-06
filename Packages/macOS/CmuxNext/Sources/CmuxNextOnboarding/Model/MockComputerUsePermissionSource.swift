public import Foundation

/// Grants set by hand, for the gallery and tests. Records which panes were opened.
@MainActor
public final class MockComputerUsePermissionSource: ComputerUsePermissionSource {
    public let helperAppURL: URL
    public private(set) var opened: [ComputerUsePermissionPane] = []
    public var current: ComputerUsePermissions {
        didSet { continuations.values.forEach { $0.yield(current) } }
    }
    private var continuations: [UUID: AsyncStream<ComputerUsePermissions>.Continuation] = [:]

    public init(current: ComputerUsePermissions = .none,
                helperAppURL: URL = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Library/cmux Computer Use.app")) {
        self.current = current
        self.helperAppURL = helperAppURL
    }

    public func permissions() -> AsyncStream<ComputerUsePermissions> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ComputerUsePermissions>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(current)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
        return stream
    }

    public func openSettings(_ pane: ComputerUsePermissionPane) { opened.append(pane) }
}
