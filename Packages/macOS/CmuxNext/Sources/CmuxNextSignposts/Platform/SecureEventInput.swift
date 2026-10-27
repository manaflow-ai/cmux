// The system's secure event input, which ``KeyFrameSignpost`` reads once per key-down. On macOS it is Carbon's
// `IsSecureEventInputEnabled`. Linux has no such state, so there it is never on.

#if canImport(Carbon)
import Carbon.HIToolbox
#endif

extension KeyFrameSignpost {
    /// Whether the system's secure event input is on now (a focused password field, a terminal's password prompt).
    nonisolated static func systemSecureEventInput() -> Bool {
        #if canImport(Carbon)
        IsSecureEventInputEnabled()
        #else
        false
        #endif
    }
}
