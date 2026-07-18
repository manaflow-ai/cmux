internal import CmuxTerminalRenderProtocol
public import Foundation

/// Exact worker-owned grid geometry for one rendered presentation lifetime.
public struct RendererPresentationReady: Equatable, Sendable {
    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let canonicalSequence: UInt64
    public let presentationSequence: UInt64
    public let columns: UInt32
    public let rows: UInt32
    public let cellWidth: UInt32
    public let cellHeight: UInt32
    public let paddingTop: UInt32
    public let paddingRight: UInt32
    public let paddingBottom: UInt32
    public let paddingLeft: UInt32

    /// Creates a worker-owned geometry reply fenced to the scene that produced it.
    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        canonicalSequence: UInt64,
        presentationSequence: UInt64,
        columns: UInt32,
        rows: UInt32,
        cellWidth: UInt32,
        cellHeight: UInt32,
        paddingTop: UInt32,
        paddingRight: UInt32,
        paddingBottom: UInt32,
        paddingLeft: UInt32
    ) throws {
        try RendererControlValidation.validateIdentity(terminalID)
        try RendererControlValidation.validateIdentity(presentationID)
        let maximum = TerminalRenderFrameProtocol.maximumDimension
        guard terminalEpoch != 0,
              presentationGeneration != 0,
              canonicalSequence != 0,
              presentationSequence != 0,
              columns > 0,
              columns <= maximum,
              rows > 0,
              rows <= maximum,
              cellWidth > 0,
              cellWidth <= maximum,
              cellHeight > 0,
              cellHeight <= maximum,
              paddingTop <= maximum,
              paddingRight <= maximum,
              paddingBottom <= maximum,
              paddingLeft <= maximum else {
            throw RendererControlError.invalidPresentationMetrics
        }
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.canonicalSequence = canonicalSequence
        self.presentationSequence = presentationSequence
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingTop = paddingTop
        self.paddingRight = paddingRight
        self.paddingBottom = paddingBottom
        self.paddingLeft = paddingLeft
    }
}
