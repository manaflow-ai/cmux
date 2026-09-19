import Foundation

/// Protects one restored command while its new terminal has not yet been observed.
struct RestoredProcessDetectedBinding: Sendable {
    private var binding: SurfaceResumeBindingSnapshot?
    private let deadlineUptime: TimeInterval

    init?(
        binding: SurfaceResumeBindingSnapshot?,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard let binding, binding.isProcessDetected else { return nil }
        self.binding = binding
        // Allow three normal autosave intervals for the paced PTY/login-shell
        // launch. Reading or saving again never extends this deadline.
        deadlineUptime = nowUptime + 3 * SessionPersistencePolicy.autosaveInterval
    }

    /// A projection is read-only and applies only to the exact restored binding.
    func preserves(
        _ storedBinding: SurfaceResumeBindingSnapshot?,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        binding != nil && binding == storedBinding && nowUptime < deadlineUptime
    }

    /// Positive observation, replacement, removal, or expiry ends preservation permanently.
    mutating func observe(
        storedBinding: SurfaceResumeBindingSnapshot?,
        detectedBinding: SurfaceResumeBindingSnapshot?,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        if detectedBinding != nil || !preserves(storedBinding, nowUptime: nowUptime) {
            binding = nil
        }
    }
}
