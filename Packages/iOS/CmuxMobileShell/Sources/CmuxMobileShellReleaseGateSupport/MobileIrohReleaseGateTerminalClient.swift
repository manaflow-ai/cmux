#if DEBUG
public import Foundation
public import CmuxMobileShell
public import CmuxMobileShellModel

/// The same terminal delivery boundary used by the mounted iOS renderer.
@MainActor
public protocol MobileIrohReleaseGateTerminalClient: AnyObject {
    /// Opens the renderer's output stream for one owner.
    func terminalOutputStream(surfaceID: String, ownerID: UUID?) -> AsyncStream<MobileTerminalOutputChunk>
    /// Reports whether this owner still owns the renderer stream.
    func isTerminalOutputConsumerOwner(surfaceID: String, ownerID: UUID) -> Bool
    /// Releases this owner's renderer stream.
    func clearTerminalOutputConsumerOwner(surfaceID: String, ownerID: UUID)
    /// Acknowledges a delivered output chunk.
    func terminalOutputDidProcess(surfaceID: String, streamToken: UUID)
    /// Sends raw terminal input through the mounted surface.
    func submitTerminalRawInput(_ data: Data, surfaceID: String) async
}

extension MobileShellComposite: MobileIrohReleaseGateTerminalClient {}
#endif
