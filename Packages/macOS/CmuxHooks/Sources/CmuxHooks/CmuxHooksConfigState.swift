import Foundation

/// The current decoded state of hook configuration.
public enum CmuxHooksConfigState: Sendable, Equatable {
    /// No config file exists, or the file has no textual/decoded `hooks` section.
    case absent

    /// The `hooks` section decoded successfully.
    case loaded(CmuxHooksConfig)

    /// A `hooks` section appears to be configured but could not be decoded.
    case broken(reason: String)
}
