/// `app.quitBehavior` and `app.confirmQuit` are retired (schemas/settings/retired-keys.json, CMUX-630): there is one
/// Quit, which quits the app and keeps every session running (Leo 2026-11-15: "we should just have the one quit and
/// it's the same quit when i right click the icon in the dock and it quits while keeping the background services
/// alive. just less to think about"), and no quit asks first.
public nonisolated enum RetiredQuitSettings {
    /// The retired keys' paths in cmux.json.
    public static let paths: [[String]] = [["app", "quitBehavior"], ["app", "confirmQuit"]]
}

extension SettingsController {
    /// Removes `app.quitBehavior` and `app.confirmQuit` from cmux.json once at launch, so the file
    /// no longer names choices nothing reads, and drops an `app` object they leave empty.
    /// Returns whether it wrote.
    @discardableResult
    public func removeRetiredQuitSettings() async throws -> Bool {
        var removed = false
        for path in RetiredQuitSettings.paths where try await file.value(at: path) != nil {
            try await file.remove(path)
            removed = true
        }
        guard removed else { return false }
        try await pruneEmpty(["app"])
        await reloadAfterWrite()
        return true
    }
}
