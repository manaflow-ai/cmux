public import Foundation

/// Transport-neutral terminal-output frame delivered by an independent lane.
public struct MobileTerminalLaneOutputFrame: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case replay
        case chunk
    }

    public let kind: Kind
    public let retainedBaseSequence: UInt64
    public let sequence: UInt64
    public let currentSequence: UInt64
    public let bytes: Data

    public init(
        kind: Kind,
        retainedBaseSequence: UInt64,
        sequence: UInt64,
        currentSequence: UInt64,
        bytes: Data
    ) {
        self.kind = kind
        self.retainedBaseSequence = retainedBaseSequence
        self.sequence = sequence
        self.currentSequence = currentSequence
        self.bytes = bytes
    }
}
