internal import Foundation

/// The outcome of the v1 `clear_meta_block` command's tab+key resolution.
public enum ControlSidebarClearMetaBlockResolution: Sendable, Equatable {
    /// The target tab could not be resolved.
    case tabNotFound
    /// The block existed and was removed.
    case removed
    /// The tab resolved but no block had the key (legacy `OK (key not found)`).
    case keyNotFound
}
