import Foundation

/// One script batch's part of a ``StoreStage`` (``DaemonStore/openStage(for:until:clock:)``): the
/// batch ends its part with ``commit()``, and the stage shows what it held when every batch that
/// joined it ended.
///
/// ```swift
/// let batch = store.openStage(for: scope, until: .now + .seconds(2))
/// // ... the batch's ops run under `scope` ...
/// batch.commit()
/// ```
@MainActor
public final class StoreStageBatch {
    /// The stage this batch joined.
    public let stage: StoreStage
    private var isEnded = false

    init(stage: StoreStage) {
        self.stage = stage
    }

    /// Ends this batch's part, once: a second call does nothing, so one batch never ends another's.
    public func commit() {
        guard !isEnded else { return }
        isEnded = true
        stage.end(self)
    }
}
