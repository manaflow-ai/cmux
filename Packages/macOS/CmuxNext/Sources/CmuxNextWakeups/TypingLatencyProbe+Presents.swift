public import CmuxNextSignposts

/// The echo commits' presents (p09-observability 037): the run-loop end after a press's
/// ``TypingLatencyProbe/Mark/contents`` keeps its flow and its terminal's display, and the presents'
/// commit observer, which runs after it in the same turn end, takes them
/// (``FramePresentEstimate/pendingCommits``), so the first vsync of that display after the commit writes
/// the press's `frame.present_estimate`.
extension TypingLatencyProbe {
    /// A flow whose echo frame went to its layer, and its terminal's display.
    struct EchoCommit {
        var flow: UInt64
        var display: UInt32?
        /// Its frame went to its layer before its GPU work finished (``mark(_:surface:awaitsGPU:)``).
        var awaitsGPU = false
    }

    /// The echo commits of this turn end whose display is known, oldest first; nil-display ones are not
    /// kept. The composition root sets it as ``FramePresentEstimate/pendingCommits``.
    public func takePresentCommits() -> [FramePresentEstimate.Commit] {
        state.withLock { state in
            defer { state.presentCommits.removeAll(keepingCapacity: true) }
            return state.presentCommits
        }
    }
}

extension TypingLatencyProbe.State {
    /// Keeps `commits` with a known display for ``TypingLatencyProbe/takePresentCommits()``; the oldest
    /// go past ``TypingLatencyProbe/openCapacity`` (nothing takes them while the frame category is off).
    mutating func keepForPresents(_ commits: [TypingLatencyProbe.EchoCommit]) {
        for commit in commits {
            guard let display = commit.display else { continue }
            if presentCommits.count >= TypingLatencyProbe.openCapacity { presentCommits.removeFirst() }
            presentCommits.append(FramePresentEstimate.Commit(flow: commit.flow, display: display, awaitsGPU: commit.awaitsGPU))
        }
    }
}
