extension SettingsController {
    /// Writes `updates.downloadAutomatically: true` for an app whose channel downloads by default
    /// (NIGHTLY, DEV) while no layer sets it: at launch, and again after Reset removes it, so the
    /// Settings window shows what the app applies. A value the person (or a managed layer) wrote
    /// stays; the write is atomic against theirs (``CmuxConfigFile/setIfAbsent(_:at:)``). Returns
    /// whether it wrote.
    @discardableResult
    public func seedDownloadAutomatically(channelDefault: Bool) async throws -> Bool {
        guard channelDefault, snapshot.root.value(at: UpdatesSettings.downloadAutomaticallyPath) == nil else { return false }
        return try await file.setIfAbsent(.bool(true), at: UpdatesSettings.downloadAutomaticallyPath)
    }
}
