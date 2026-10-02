internal import CmuxMobileShellModel
internal import Foundation

/// One discovered model response and the time the phone fetched it.
struct MobileTaskModelCacheEntry: Equatable {
    let result: MobileTaskModelListResult
    let fetchedAt: Date
    /// The exact live client that produced an authoritative host catalog.
    /// Backend entries intentionally leave this unset because they are not
    /// tied to one connection instance.
    let connectionIdentity: String?
}
