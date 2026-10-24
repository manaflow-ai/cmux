import CmuxNextCompat

extension ThemeStore {
    /// Repaints every window (``repaintAll(crossfade:)``) after each change of the value `read`
    /// returns, for settings that move no theme color but every window draws (borders, calm mode,
    /// the terminal face pages follow).
    ///
    /// `read` is evaluated once before this returns, with its Observation tracking armed, so a
    /// change right after the call repaints. Event-driven (Observation): no timer, no polling. An
    /// equal value does not repaint. The task ends when it is cancelled, when `read` returns nil
    /// (its source is gone), or when this store is gone.
    ///
    /// ```swift
    /// let task = store.repaintAll(following: { [weak design] in design?.windowDrawn })
    /// ```
    /// - Parameter read: The observable value whose changes repaint; nil ends the task.
    /// - Returns: The observing task; its owner keeps it and cancels it.
    public func repaintAll<Inputs: Equatable & Sendable>(
        following read: @escaping @MainActor @Sendable () -> Inputs?
    ) -> Task<Void, Never> {
        let (initial, later) = ObservationStream.current(read)
        // task-owner: the caller (it keeps and cancels the returned task); event-driven (Observation)
        return Task { [weak self] in
            var last = initial
            for await next in later {
                guard let next, let self else { return }
                guard next != last else { continue }
                last = next
                self.repaintAll()
            }
        }
    }
}
