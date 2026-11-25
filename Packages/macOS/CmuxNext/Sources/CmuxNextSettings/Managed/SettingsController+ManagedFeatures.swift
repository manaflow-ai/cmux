extension SettingsController {
    /// Applies `DisabledFeatures` from a synchronous read of the forced
    /// managed values, before Cloud, SSH and apps start, so no feature runs
    /// in the window before the first full settings load.
    /// The forced managed values, read synchronously (launch only: later
    /// changes arrive through ``managedPolicy``).
    public func forcedManagedValuesNow() -> [String: JSONValue] { managedReader.read().forced }

    public func applyManagedFeaturesNow() {
        applier.registry.disabledFeatures = ManagedPreferences.disabledFeatures(in: managedReader.read().forced).features
    }
}
