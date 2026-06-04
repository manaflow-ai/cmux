public import Foundation

/// Failures initializing the libghostty engine.
public enum GhosttyEngineError: LocalizedError {
    /// `ghostty_init` returned a non-success code.
    case backendInitFailed(code: Int32)
    /// `ghostty_app_new` returned `nil`.
    case appCreationFailed

    /// A localized, user-presentable description of the failure.
    public var errorDescription: String? {
        switch self {
        case .backendInitFailed(let code):
            return String(
                format: String(
                    localized: "terminal.runtime.init_failed",
                    defaultValue: "libghostty initialization failed (%d)"
                ),
                Int(code)
            )
        case .appCreationFailed:
            return String(
                localized: "terminal.runtime.app_creation_failed",
                defaultValue: "libghostty app creation failed"
            )
        }
    }
}
