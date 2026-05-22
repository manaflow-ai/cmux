public struct VNCVisibilityFrameGate: Equatable, Sendable {
    public private(set) var isVisible: Bool
    public private(set) var sequence: UInt64

    public init(isVisible: Bool = true, sequence: UInt64 = 0) {
        self.isVisible = isVisible
        self.sequence = sequence
    }

    public mutating func setVisible(_ visible: Bool) -> UInt64? {
        guard isVisible != visible else { return nil }
        isVisible = visible
        if visible {
            return nextSequence()
        }
        return nil
    }

    public mutating func nextUpdateSequence() -> UInt64? {
        guard isVisible else { return nil }
        return nextSequence()
    }

    private mutating func nextSequence() -> UInt64 {
        sequence &+= 1
        return sequence
    }
}
