extension BackgroundWork {
    /// One item's budget on `lane` (a jank past it, a hang dump 2 s later): a file operation 5 s,
    /// a system call 30 s (`getaddrinfo`'s own timeout, see ``systemWidth``), CPU work 10 s.
    public static func hangDeadline(_ lane: BlockingLane) -> Duration {
        switch lane {
        case .files: .seconds(5)
        case .system: .seconds(30)
        case .cpu: .seconds(10)
        }
    }

    /// The name a hang report gives an item of `lane`.
    static func hangScopeName(_ lane: BlockingLane) -> StaticString {
        switch lane {
        case .files: "lane.files"
        case .system: "lane.system"
        case .cpu: "lane.cpu"
        }
    }
}
