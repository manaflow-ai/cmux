import Foundation

/// Aborts the run with `message` unless the caller cancels the returned task
/// first.
///
/// The waits this guards are event-driven: they suspend until the fake they
/// wait on resumes them, so a run that reaches this deadline is one where the
/// awaited edge never arrived. Reporting that by name beats leaving the run
/// suspended forever. The deadline is generous on purpose — it never bounds a
/// passing run, so machine load cannot push a healthy wait past it.
@MainActor
func failAfterDeadline(
    _ timeout: Duration,
    _ message: @escaping @MainActor () -> String
) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        preconditionFailure(message())
    }
}
