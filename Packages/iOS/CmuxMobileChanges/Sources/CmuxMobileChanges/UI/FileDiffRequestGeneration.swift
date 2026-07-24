/// Invalidates asynchronous diff-page work when a newer user request begins.
struct FileDiffRequestGeneration: Sendable {
    private var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == current
    }
}
