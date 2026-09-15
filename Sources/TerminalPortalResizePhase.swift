/// Owns the boundary between live pane geometry and committed renderer sizes.
struct TerminalPortalResizePhase {
    private enum Phase: Equatable {
        case idle
        case resizing
        case ending
        case completedAwaitingNativeEnd
    }

    private var phase = Phase.idle

    var defersRenderer: Bool {
        phase == .resizing || phase == .ending
    }

    var isEnding: Bool { phase == .ending }

    mutating func begin() {
        phase = .resizing
    }

    mutating func requestEnd() {
        phase = .ending
    }

    /// Ignores callbacks from a completed resize until AppKit clears its signal
    /// or an explicit start establishes a new resize transaction.
    mutating func observeNativeResize(active: Bool) -> Bool {
        switch (phase, active) {
        case (.completedAwaitingNativeEnd, true):
            return false
        case (.completedAwaitingNativeEnd, false):
            phase = .idle
        case (.idle, true):
            phase = .resizing
        default:
            break
        }
        return true
    }

    /// Releases publication only after the portal installs final pane geometry.
    mutating func commitEnd(nativeResizeActive: Bool) {
        phase = nativeResizeActive ? .completedAwaitingNativeEnd : .idle
    }

    mutating func reset() {
        phase = .idle
    }
}
