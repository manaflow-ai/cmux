/// Tells the ``MainFrameBudget`` when the render pass of a budgeted link tick that came after the last
/// discrete input ended (``MainFrameBudget/noteTickRenderEnded()``): the end of the input response.
///
/// Chrome's renderer scheduler leaves `RenderingPrioritizationState::kWaitingForInputResponse` once the
/// frame after the input was produced (`third_party/blink/renderer/platform/scheduler/main_thread/
/// main_thread_scheduler_impl.cc`, `DidCommitFrameToCompositor`), not at the input's own turn. Here the frame
/// is the render pass (``RenderPassMeter``) of a turn in which the budgeted ``FrameScheduler`` ticked after
/// the input. A tick that ran before the input in the input's own turn does not count, so the input's own
/// commit never ends its response.
@MainActor
final class TickRenderReporter {
    private let frames: FrameScheduler
    private let budget: MainFrameBudget
    /// The link's tick count when the last discrete input was noted.
    private var ticksAtInput: UInt64 = 0
    /// The link's tick count at the last render pass.
    private var ticksAtPass: UInt64 = 0

    init(frames: FrameScheduler, budget: MainFrameBudget) {
        self.frames = frames
        self.budget = budget
    }

    /// A discrete input's dispatch ended; `expectsFrame` opens the budget's input response.
    func noteDiscreteInput(expectsFrame: Bool) {
        ticksAtInput = frames.frames
        budget.noteDiscreteInput(expectsFrame: expectsFrame)
    }

    /// One render pass ended, `nanos` long: charged to the next frame, and the end of the input response
    /// when the link ticked since the last pass and since the last input.
    func renderPassEnded(nanos: UInt64) {
        budget.noteRenderPass(nanos: nanos)
        let ticks = frames.frames
        defer { ticksAtPass = ticks }
        if ticks != ticksAtPass, ticks != ticksAtInput { budget.noteTickRenderEnded() }
    }
}
