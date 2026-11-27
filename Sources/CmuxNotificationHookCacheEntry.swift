/// Stores resolved hooks and their content-sensitive fingerprints for one cache key.
struct CmuxNotificationHookCacheEntry {
    let fingerprints: [CmuxNotificationHookFileFingerprint]
    let hooks: [CmuxResolvedNotificationHook]
    var lastAccessSequence: UInt64
}
