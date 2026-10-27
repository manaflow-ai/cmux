public import CmuxNextInputCore
public import CmuxNextSignposts

extension InputLatencySignpostMessage {
    /// The `input.latency` fields of a closed slot: stage offsets in microseconds after its generated time, -1 for
    /// a skipped stage. A stack value: no allocation.
    ///
    /// - Parameter slot: A slot ``InputLatencyTracker`` closed.
    public nonisolated init(slot: InputLatencySlot) {
        self.init()
        kind = slot.kind.rawValue
        target = slot.target.rawValue
        entrypoint = slot.entrypoint.rawValue
        presentationSource = slot.presentationSource.rawValue
        variableRefresh = slot.isVariableRefresh
        coalescedCount = UInt32(slot.coalescedCount)
        causedFrameUpdate = slot.causedFrameUpdate
        let origin = slot.generated
        generatedNanos = origin
        lastGeneratedMicros = Self.micros(slot.lastGenerated, after: origin)
        arrivedMainMicros = Self.micros(slot.arrivedMain, after: origin)
        dispatchStartMicros = Self.micros(slot.dispatchStart, after: origin)
        textInputStartMicros = Self.micros(slot.textInputStart, after: origin)
        textInputEndMicros = Self.micros(slot.textInputEnd, after: origin)
        dispatchEndMicros = Self.micros(slot.dispatchEnd, after: origin)
        mainCommitMicros = Self.micros(slot.mainCommit, after: origin)
        contentSubmittedMicros = Self.micros(slot.contentSubmitted, after: origin)
        daemonReceivedMicros = Self.micros(slot.daemonReceived, after: origin)
        ptyWrittenMicros = Self.micros(slot.ptyWritten, after: origin)
        echoReadMicros = Self.micros(slot.echoRead, after: origin)
        echoSentMicros = Self.micros(slot.echoSent, after: origin)
        presentedMicros = Self.micros(slot.presented, after: origin)
    }

    /// The trace ring's `arg0` for this event (``SignpostName/inputLatency``): kind | target << 8 | entrypoint << 16
    /// | source << 24 | caused frame update << 32 | variable refresh << 33.
    public nonisolated var traceArg0: UInt64 {
        UInt64(kind) | UInt64(target) << 8 | UInt64(entrypoint) << 16 | UInt64(presentationSource) << 24
            | (causedFrameUpdate ? UInt64(1) << 32 : 0) | (variableRefresh ? UInt64(1) << 33 : 0)
    }

    /// The trace ring's `arg1`: generated to presented in microseconds, 0 when the presented stage was skipped.
    public nonisolated var traceArg1: UInt64 {
        presentedMicros > 0 ? UInt64(presentedMicros) : 0
    }
}
