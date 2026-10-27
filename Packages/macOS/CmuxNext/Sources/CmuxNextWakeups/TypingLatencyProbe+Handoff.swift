import CmuxNextSignposts

/// The app's thread handoffs of a key's echo (p09-observability-102; ghostty-integration-DESIGN.md "Key to
/// frame"): each a `key.echo.*` flow out where a thread queues the echo's item (``queued(_:flow:surface:)``)
/// and a flow in where the next thread takes it (``taken(_:flow:surface:)``), with the press's flow id the
/// item carries. Chrome marks a posted task the same way: `TaskAnnotator::WillQueueTask` writes the flow
/// out and `TaskAnnotator::RunTask` the flow in, with the id the `PendingTask` carries
/// (base/task/common/task_annotator.cc). The Rust processes mark the six handoffs before these
/// (`cmux_flow_trace::Handoff`).
extension TypingLatencyProbe {
    /// A handoff of the echo in the app, named by the thread that queues it.
    public enum Handoff: Sendable, CaseIterable {
        /// The daemon's line-out thread wrote the event; the attach reader reads it (`key.echo.line_out`).
        case lineOut
        /// The attach reader hands the event on (decoded, then queued for the session); the session's event
        /// loop takes it (`key.echo.app_transport_read`).
        case appTransportRead
        /// The session's event loop hands the event to the router of the surface's lane
        /// (`key.echo.main_actor`: the main actor's hop until G4 took output off it).
        case mainActor
        /// The router queues the echo's chunk on the output lane; the lane parses it (`key.echo.output_lane`).
        case outputLane
        /// The lane's parse wakes the renderer; the renderer thread draws the frame (`key.echo.renderer`).
        case renderer
        /// The renderer committed the frame's GPU work; its Metal completion handler runs (`key.echo.gpu_done`).
        case gpuDone
        /// The frame goes to its layer; the main run-loop turn that sets it ends (`key.echo.contents`).
        case contents

        /// The handoff's catalog name.
        var name: SignpostName {
            switch self {
            case .lineOut: .keyEchoLineOut
            case .appTransportRead: .keyEchoAppTransportRead
            case .mainActor: .keyEchoMainActor
            case .outputLane: .keyEchoOutputLane
            case .renderer: .keyEchoRenderer
            case .gpuDone: .keyEchoGPUDone
            case .contents: .keyEchoContents
            }
        }
    }

    /// The calling thread queued key press `flow`'s item for `handoff`'s next thread: its flow out (`s`),
    /// arg0 the surface's ``SurfaceKey/traceID`` (0 where the thread does not know it). Nothing for flow 0,
    /// while key flows are off (one load) or while the keystroke-timing gate is closed.
    public func queued(_ handoff: Handoff, flow: UInt64, surface: UInt64 = 0) {
        guard flow != 0, flowsStarted, !trace.isKeyTimingSuppressed else { return }
        trace.flowOut(handoff.name, flow: flow, arg0: surface)
    }

    /// `handoff`'s next thread (the caller) took key press `flow`'s item: its flow in (`f`). Nothing when
    /// ``queued(_:flow:surface:)`` writes nothing.
    public func taken(_ handoff: Handoff, flow: UInt64, surface: UInt64 = 0) {
        guard flow != 0, flowsStarted, !trace.isKeyTimingSuppressed else { return }
        trace.flowIn(handoff.name, flow: flow, arg0: surface)
    }
}
