public import Foundation

/// Worker acknowledgement that one exact presentation stopped publishing frames.
///
/// The daemon may drain and destroy that presentation's Mach receive endpoint
/// only after this acknowledgement arrives. Frames sent before the removal
/// remain individually leased until the host returns their exact releases.
public struct RendererPresentationRemoved: Equatable, Sendable {
    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64

    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64
    ) throws {
        try RendererControlValidation.validateIdentity(terminalID)
        try RendererControlValidation.validateIdentity(presentationID)
        guard presentationGeneration != 0 else {
            throw RendererControlError.zeroPresentationGeneration
        }
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
    }
}
