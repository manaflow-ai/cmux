/// Invalidates asynchronous diff-page work when a newer user request begins.
struct FileDiffRequestGeneration: Sendable {
    private var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    mutating func invalidate() {
        current &+= 1
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == current
    }
}
