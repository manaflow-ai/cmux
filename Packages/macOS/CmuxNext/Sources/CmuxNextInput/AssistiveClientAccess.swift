public import Foundation
import CmuxNextCompat

/// The seam where AppKit's nonisolated accessibility calls on the application element reach the
/// assistive clients' requests. Each entry checks the thread first: a call off the main thread is
/// not one of ours (it answers nil or false and the caller asks super). The requests sit behind a
/// lock, so the type is Sendable; the follower is main-actor and runs on main only.
public nonisolated final class AssistiveClientAccess: Sendable {
    private struct State {
        var requests = AssistiveClientRequests()
        var changed: (@MainActor @Sendable (Bool) -> Void)?
    }
    private let state = Mutex(State())

    public init() {}

    /// Follows whether the app wants page accessibility, told the current state at once.
    @MainActor public func follow(_ changed: (@MainActor @Sendable (Bool) -> Void)?) {
        let wants = state.withLock { state in
            state.changed = changed
            return state.requests.wantsAccessibility
        }
        changed?(wants)
    }

    /// Records an assistive client's `value` for `attribute`; false when the call is not one this
    /// handles (another attribute, or off the main thread).
    public func set(_ value: NSNumber?, for attribute: String) -> Bool {
        guard AssistiveClientRequests.attributes.contains(attribute), Thread.isMainThread else { return false }
        let (flipped, changed) = state.withLock { state -> (Bool?, (@MainActor @Sendable (Bool) -> Void)?) in
            let wanted = state.requests.wantsAccessibility
            _ = state.requests.set(value, for: attribute)
            let now = state.requests.wantsAccessibility
            return (now != wanted ? now : nil, state.changed)
        }
        if let flipped, let changed {
            // main-proof: checked Thread.isMainThread at the top of this function.
            MainActor.assumeIsolated { changed(flipped) }
        }
        return true
    }

    /// `.some(answer)` for an attribute this handles on the main thread; nil otherwise.
    public func value(for attribute: String) -> Bool?? {
        guard AssistiveClientRequests.attributes.contains(attribute), Thread.isMainThread else { return nil }
        return .some(state.withLock { $0.requests.value(for: attribute) })
    }
}
