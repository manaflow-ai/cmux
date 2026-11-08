import Foundation

/// Couples a hook file's cache identity with the exact bytes represented by that identity.
struct CmuxNotificationHookFileSnapshot {
    let fingerprint: CmuxNotificationHookFileFingerprint
    let contents: Data?
}
