import Foundation

/// Synchronous seam from the vendored layer renderer into the host's main-actor Home motion gate.
enum HomeTypingMotionGate {
    /// Whether the host lets Home loops run; off the main thread it answers no.
    static func allowsLoops() -> Bool {
        guard Thread.isMainThread else { return false }
        // main-proof: guarded by Thread.isMainThread above; layer decoration runs on the main thread.
        return MainActor.assumeIsolated { MessagesLabHomeView.voiceMotionGate() }
    }
}
