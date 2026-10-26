public import CmuxNextSignposts

/// The echo commits' presents (p09-observability 037): the run-loop end after a press's
/// ``TypingLatencyProbe/Mark/contents`` hands its flow and its terminal's display to
/// ``FramePresentEstimate/markCommit(flow:display:awaitsGPU:)``, so the first vsync of that display after
/// the commit writes the press's `frame.present_estimate`.
extension TypingLatencyProbe {
    /// A flow whose echo frame went to its layer, and its terminal's display.
    struct EchoCommit {
        var flow: UInt64
        var display: UInt32?
    }

    /// Echo commits from now on also date their present on `presents` (`frame.present_estimate`, while
    /// the frame category records), on the display of the terminal the key went to (the composition root).
    public func attach(presents: FramePresentEstimate) {
        state.withLock { $0.presents = presents }
    }
}
