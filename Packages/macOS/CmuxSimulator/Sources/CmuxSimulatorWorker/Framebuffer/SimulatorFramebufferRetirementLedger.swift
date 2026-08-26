actor SimulatorFramebufferRetirementLedger {
    private let maximumRetiredNameCount: Int
    private var retiredNames: Set<String> = []

    init(maximumRetiredNameCount: Int = 32) {
        self.maximumRetiredNameCount = max(1, maximumRetiredNameCount)
    }

    var count: Int {
        retiredNames.count
    }

    @discardableResult
    func recordRetired(_ name: String) -> Bool {
        guard retiredNames.contains(name)
            || retiredNames.count < maximumRetiredNameCount else { return false }
        retiredNames.insert(name)
        return true
    }

    func takeRetiredNames() -> Set<String> {
        defer { retiredNames.removeAll() }
        return retiredNames
    }
}
