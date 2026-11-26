/// Associates a parsed notification-hook configuration with its content fingerprint.
struct CmuxNotificationHookParsedConfig {
    let fingerprint: CmuxNotificationHookFileFingerprint
    let config: CmuxConfigFile?
}
