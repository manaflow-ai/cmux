/// Bounded startup read measurements, containing no user payload or paths.
struct WorkstreamStartupDiagnostics: Sendable, Equatable {
    let elapsedNanoseconds: UInt64
    let fileBytes: UInt64
    let exceededBudget: Bool
    let missingFile: Bool
}
