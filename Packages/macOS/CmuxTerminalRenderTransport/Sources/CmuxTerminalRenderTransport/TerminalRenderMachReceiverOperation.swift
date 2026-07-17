internal import CmuxTerminalRenderProtocol
internal import Foundation
internal import TerminalRenderMachIPC

/// Performs one nonblocking kernel receive after a Mach readiness signal.
struct TerminalRenderMachReceiverOperation: Sendable {
    let receivePort: UInt32
    let capability: Data
    let expectedWorker: TerminalRenderWorkerIdentity

    func run(timeoutMilliseconds: UInt32) -> TerminalRenderRawReceiveResult {
        var received = cmux_terminal_render_received_frame_s()
        var machError: kern_return_t = KERN_SUCCESS
        let status = capability.withUnsafeBytes { capabilityBytes in
            cmux_terminal_render_frame_receive(
                receivePort,
                timeoutMilliseconds,
                capabilityBytes.bindMemory(to: UInt8.self).baseAddress!,
                expectedWorker.processID,
                expectedWorker.effectiveUserID,
                &received,
                &machError
            )
        }
        let metadata: Data?
        if status == CMUX_TERMINAL_RENDER_STATUS_SUCCESS {
            metadata = withUnsafeBytes(of: received.metadata) { Data($0) }
        } else {
            metadata = nil
        }
        return TerminalRenderRawReceiveResult(
            status: status.rawValue,
            machError: machError,
            metadata: metadata,
            surfacePort: received.surface_port,
            senderProcessID: received.sender_pid,
            senderEffectiveUserID: received.sender_euid
        )
    }
}
