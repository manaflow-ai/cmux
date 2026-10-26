extension SettingsController {
    /// Writes `updates.downloadAutomatically: true` once for an install that never set it, in an
    /// app whose channel downloads by default (NIGHTLY, DEV): the Settings window then shows what
    /// the app applies. A value the person (or a managed layer) wrote stays. Returns whether it wrote.
    @discardableResult
    public func seedDownloadAutomatically(channelDefault: Bool) async throws -> Bool {
        guard channelDefault, snapshot.root.value(at: UpdatesSettings.downloadAutomaticallyPath) == nil,
              try await file.value(at: UpdatesSettings.downloadAutomaticallyPath) == nil else { return false }
        try await file.set(.bool(true), at: UpdatesSettings.downloadAutomaticallyPath)
        return true
    }
}
