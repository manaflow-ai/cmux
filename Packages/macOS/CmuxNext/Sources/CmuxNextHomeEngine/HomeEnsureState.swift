public import CmuxNextWindowRules
public import Observation

/// This app's `ensure_home` requests (`HomeService.ensureHomeWorkspace`), and what the launch rule
/// (cmux-window-rules `launch::fresh_landing`) reads of them: whether Home is not ensured yet.
@MainActor @Observable
public final class HomeEnsureState {
    /// An `ensure_home` is in flight. A tree snapshot taken meanwhile can show the new home workspace
    /// before its kind row, so launch waits for the answer before it decides on a first workspace
    /// (`needsFirstWorkspace`).
    public private(set) var inFlight = false
    /// An `ensure_home` answered (named Home or failed).
    public private(set) var answered = false
    /// The app's launch starts Home (AppDelegate), maybe after its first frame: the launch waits for Home
    /// until an `ensure_home` answered. Off where nothing starts Home (tests that make the services alone).
    public var ensuresAtLaunch = false
    /// The latest `ensure_home`; only it clears `inFlight`.
    @ObservationIgnored public private(set) var generation = 0

    public init() {}

    /// Starts an `ensure_home`; its generation, for `settle`.
    public func begin() -> Int {
        generation &+= 1
        inFlight = true
        return generation
    }

    /// `generation`'s `ensure_home` answered; a newer one in flight keeps `inFlight`.
    public func settle(_ generation: Int) {
        guard self.generation == generation else { return }
        inFlight = false
        answered = true
    }

    /// The launch rule's facts before the restore places the saved windows. Home is not ensured yet while an
    /// `ensure_home` is in flight (each has the connection's timeout), or while the launch ensures Home, none
    /// answered, and the local daemon can ensure it (`canEnsure`: connected, `workspace-kind-v1`); that ends when one
    /// answers or the daemon no longer can. `ensureInFlight` is the fallback's input for a pinned FFI without the op.
    public func freshFacts(emptyTree: Bool, classicHome: Bool, homeEnsured: Bool,
                           canEnsure: Bool) -> (WindowRules.FreshFacts, ensureInFlight: Bool) {
        let notEnsuredYet = inFlight || (ensuresAtLaunch && !answered && canEnsure)
        let facts = WindowRules.FreshFacts(emptyTree: emptyTree, noSavedWindowOpen: false, classicHome: classicHome,
                                           homeEnsured: homeEnsured, homeNotEnsuredYet: notEnsuredYet)
        return (facts, inFlight)
    }
}
