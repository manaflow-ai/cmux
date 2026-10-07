import Foundation

/// Keeps a shown Search Tabs page current: on every element of the
/// source's `changes()` it re-reads the page (`PaletteModel.reload`), so a
/// tab closed anywhere leaves Open Tabs and appears under Recently Closed at
/// once. Event driven; it stops at the first change after the page is gone.
public final class TabSearchLiveUpdates {
    private var task: Task<Void, Never>?

    public init() {}

    deinit { task?.cancel() }

    /// Follows `source` for the Search Tabs page of `model`, replacing any
    /// earlier follow.
    public func follow(_ source: any TabSearchSource, in model: PaletteModel) {
        task?.cancel()
        let stream = source.changes()
        task = Task { [weak model] in
            for await _ in stream {
                guard let model, model.currentPageID == PalettePageSpec.tabSearchID else { return }
                model.reload()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
