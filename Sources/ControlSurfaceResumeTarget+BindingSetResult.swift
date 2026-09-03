/// Result of atomically checking a retry generation and applying a surface binding.
@MainActor
extension ControlSurfaceResumeTarget {
    enum BindingSetResult: Equatable {
        case applied
        case rejected
        case generationMismatch
    }
}
