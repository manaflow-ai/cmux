extension Task where Success == Void, Failure == Never {
    /// A task that waits on this one and cancels both it and `other` when cancelled: two
    /// observation loops held, and stopped, as one.
    public func cancelling(_ other: Task<Void, Never>) -> Task<Void, Never> {
        Task { await withTaskCancellationHandler { await self.value } onCancel: { self.cancel(); other.cancel() } }
    }
}
