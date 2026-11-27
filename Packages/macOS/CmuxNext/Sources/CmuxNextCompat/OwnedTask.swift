/// Owns an observation task for exactly as long as its observer keeps this handle.
/// Replacement and release cancel it without hopping to an actor during teardown.
public final class OwnedTask: Sendable {
    private let task: Task<Void, Never>

    public init(_ task: Task<Void, Never>) { self.task = task }

    deinit { task.cancel() }

    public func cancel() { task.cancel() }
}

extension Task where Success == Void, Failure == Never {
    public func owned() -> OwnedTask { OwnedTask(self) }
}
