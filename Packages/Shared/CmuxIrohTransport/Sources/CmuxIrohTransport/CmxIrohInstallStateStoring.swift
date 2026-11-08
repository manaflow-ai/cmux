/// Non-secret installation state used to detect reinstall and account changes.
public protocol CmxIrohInstallStateStoring: Sendable {
    /// Returns the value for a repository-owned state key.
    func string(forKey key: String) -> String?

    /// Sets or clears the value for a repository-owned state key.
    func set(_ value: String?, forKey key: String)
}
