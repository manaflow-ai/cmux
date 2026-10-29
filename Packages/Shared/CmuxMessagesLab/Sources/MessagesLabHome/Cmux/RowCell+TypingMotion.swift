import AppKit

extension RowCell {
    /// The typing dots and breath hold still: Reduce Motion, or the host's Home motion gate is closed
    /// (cmux-next: animation speed off, Home animations off, or the master animation switch off).
    static var typingLoopsHeld: Bool {
        MessagesLabHomeView.reducesMotion || !HomeTypingMotionGate.allowsLoops()
    }
}

/// Synchronous seam from the vendored layer renderer into the host's actor-isolated motion gate.
private enum HomeTypingMotionGate {
    static func allowsLoops() -> Bool {
        guard Thread.isMainThread else { return false }
        // main-proof: guarded by Thread.isMainThread above; layer decoration runs on the main thread.
        return MainActor.assumeIsolated { MessagesLabHomeView.voiceMotionGate() }
    }
}
