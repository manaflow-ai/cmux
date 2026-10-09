import CmuxLink

extension InMemoryUnderlayNetwork: UnderlayFaults {
    public func throttle(bytesPerSecond: Int?) async -> Bool {
        var next = await conditions
        next.bytesPerSecond = bytesPerSecond
        await setConditions(next)
        return true
    }
}
