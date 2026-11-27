/// Identifies notification-hook resolution for one working directory and global configuration.
struct CmuxNotificationHookCacheKey: Hashable {
    let directory: String?
    let globalConfigPath: String
}
