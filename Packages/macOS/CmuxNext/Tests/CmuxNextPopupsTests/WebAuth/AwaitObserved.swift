import Observation

/// Returns once `condition` holds, waking on each change of an observable
/// value it reads (a signal, not a poll). Every value `condition` depends on
/// must be observable, or the wait only ends at the suite's time limit.
func awaitObserved(_ condition: () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
            withObservationTracking { _ = condition() } onChange: { changed.resume() }
        }
    }
}
