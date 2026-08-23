#if os(iOS)
import Foundation

/// The connect stage's read on live Mac-linking progress.
///
/// A pure projection of the shell store's discovery signals, computed by the
/// root view and handed in as a value so the stage renders identically in the
/// app, previews, and tests.
enum WelcomeConnectionStatus: Equatable {
    /// Same-account discovery is running (or about to start).
    case searching

    /// A discovery pass finished without linking a Mac; guidance and retry
    /// take over.
    case stalled

    /// A Mac is linked; `macName` is its display name when known.
    case linked(macName: String?)

    /// Folds the store's discovery signals into one stage-facing status.
    ///
    /// - Parameters:
    ///   - isConnected: Whether the shell reports a connected Mac.
    ///   - macName: The connected Mac's display name, when connected.
    ///   - isSearching: Whether a reconnect/discovery attempt is in flight
    ///     (or queued by the stage entry kick).
    ///   - didFinishSearch: Whether a full discovery attempt has concluded.
    init(isConnected: Bool, macName: String?, isSearching: Bool, didFinishSearch: Bool) {
        if isConnected {
            let trimmed = macName?.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .linked(macName: trimmed?.isEmpty == false ? trimmed : nil)
        } else if isSearching || !didFinishSearch {
            self = .searching
        } else {
            self = .stalled
        }
    }
}
#endif
