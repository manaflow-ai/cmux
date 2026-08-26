internal import CmuxMobileShellModel
internal import Foundation

/// One discovered model response and the time the phone fetched it.
struct MobileTaskModelCacheEntry: Equatable {
    let result: MobileTaskModelListResult
    let fetchedAt: Date
}
