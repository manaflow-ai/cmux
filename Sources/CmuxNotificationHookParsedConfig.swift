/// Associates a parsed notification-hook configuration with its file fingerprint.
struct CmuxNotificationHookParsedConfig {
    let fingerprint: CmuxNotificationHookFileFingerprint
    let config: CmuxConfigFile?
}
