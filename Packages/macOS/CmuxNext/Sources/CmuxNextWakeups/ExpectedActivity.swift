import Synchronization

/// Counters for work the user caused or can see: input events, animation
/// frames and terminal output. The busy watchdog treats CPU use during a
/// window with none of these as unexplained (a spin), and CPU use with any
/// of them as expected. Counting costs one relaxed atomic add.
public final class ExpectedActivity: Sendable {
    public static let shared = ExpectedActivity()

    public enum Kind: Int, CaseIterable, Sendable {
        case input, animationFrame, terminalOutput
    }

    private let input = Atomic<UInt64>(0)
    private let frames = Atomic<UInt64>(0)
    private let output = Atomic<UInt64>(0)

    public init() {}

    public func note(_ kind: Kind) {
        switch kind {
        case .input: input.add(1, ordering: .relaxed)
        case .animationFrame: frames.add(1, ordering: .relaxed)
        case .terminalOutput: output.add(1, ordering: .relaxed)
        }
    }

    public func count(_ kind: Kind) -> UInt64 {
        switch kind {
        case .input: input.load(ordering: .relaxed)
        case .animationFrame: frames.load(ordering: .relaxed)
        case .terminalOutput: output.load(ordering: .relaxed)
        }
    }

    /// Sum of every counter: unchanged across a window means no expected activity.
    public var total: UInt64 { Kind.allCases.reduce(0) { $0 &+ count($1) } }
}
