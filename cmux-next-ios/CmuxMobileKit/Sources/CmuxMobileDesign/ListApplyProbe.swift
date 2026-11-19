// DEBUG and Demo builds only: the list rig's apply probe (verify/listperf/).
#if DEBUG
import Foundation

/// Tells the list rig each time a live list applies a change to its rows (the Workspaces and Feed
/// collections), so it can count applies per second and how long a store write waited for one.
@MainActor
public final class ListApplyProbe {
    public static let shared = ListApplyProbe()

    /// Set by the rig; nil (no cost but the check) otherwise.
    public var onApply: (@MainActor (_ list: String) -> Void)?

    public init() {}

    public func applied(_ list: String) {
        onApply?(list)
    }
}
#endif
