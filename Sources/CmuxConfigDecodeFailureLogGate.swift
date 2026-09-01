/// Serializes publication of config decode failures so concurrent registry
/// loads cannot emit the same failure more than once for a file revision.
actor CmuxConfigDecodeFailureLogGate {
    private var loggedKeys: Set<String> = []

    func claim(key: String) -> Bool {
        if loggedKeys.count >= 512 {
            loggedKeys.removeAll(keepingCapacity: true)
        }
        return loggedKeys.insert(key).inserted
    }
}
