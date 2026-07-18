struct BackendOnlyHostControlDrainState: Sendable {
    struct Values: Equatable, Sendable {
        var visible = false
        var focused = false
    }

    struct Target: Equatable, Sendable {
        let revision: UInt64
        let values: Values
    }

    private(set) var desired = Values()
    private var revision: UInt64 = 0
    private var drainActive = false

    mutating func setVisibility(_ value: Bool) -> Bool {
        guard desired.visible != value else { return false }
        desired.visible = value
        advanceRevision()
        guard !drainActive else { return false }
        drainActive = true
        return true
    }

    mutating func setFocus(_ value: Bool) -> Bool {
        guard desired.focused != value else { return false }
        desired.focused = value
        advanceRevision()
        guard !drainActive else { return false }
        drainActive = true
        return true
    }

    func latestTarget() -> Target? {
        guard drainActive else { return nil }
        return Target(revision: revision, values: desired)
    }

    func isCurrent(_ target: Target) -> Bool {
        drainActive
            && target.revision == revision
            && target.values == desired
    }

    mutating func complete(_ target: Target) -> Bool {
        guard drainActive else { return false }
        guard isCurrent(target) else { return true }
        drainActive = false
        return false
    }

    mutating func cancel() {
        drainActive = false
    }

    private mutating func advanceRevision() {
        revision &+= 1
        if revision == 0 {
            revision = 1
        }
    }
}
