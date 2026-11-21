public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextSidebar
public import Foundation

/// The Chief's sidebar row by default (David Beyer's feedback, 2026-11-20: the Chief is a thread in the sidebar, not
/// only Home's first conversation): once per Mac, the first sidebar document this app loads gets the Chief right
/// under Home unless it already places one. After that the row is the person's: Remove from Sidebar keeps it out on
/// the next launch, and Add to Sidebar (or the App Store's Chief in Sidebar) brings it back.
///
/// The add runs through `sidebar.item.add` (``follow(store:registry:)``), the path Add to Sidebar takes.
///
/// ```swift
/// let offer = ChiefSidebarOffer(defaults: UserDefaults(suiteName: "test")!)
/// offer.shouldAdd(placed: false) // true: the first document without a Chief gets one
/// offer.shouldAdd(placed: false) // false: the person removed it since
/// ```
public struct ChiefSidebarOffer {
    /// The `UserDefaults` key set once the offer was made (or the document already placed the Chief).
    public static let offeredKey = "cmuxNext.sidebar.chiefRowOffered"
    private let defaults: UserDefaults

    /// - Parameter defaults: Where the once-per-Mac mark is kept (tests pass a suite of their own).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Once `store()` first holds the daemon's loaded document, adds the Chief through `sidebar.item.add` in `registry`
    /// when ``shouldAdd(placed:)`` says so (a script origin: no undo step), then stops. The real app only: tests that
    /// build an app keep their own documents.
    @MainActor
    public func follow(store: @escaping @MainActor @Sendable () -> SidebarDocStore?, registry: ActionRegistry) {
        let offer = self
        // task-owner: one wait for the first loaded document (event-driven, Observation), then one add; ends there
        Task { [weak registry] in
            for await loaded in ObservationStream({ store().map { $0.isActive && !$0.isProvisional && $0.shown != nil } ?? false }) where loaded {
                guard let registry, let document = store() else { return }
                if offer.shouldAdd(placed: document.placesItem(with: .builtIn(.chief))) {
                    let invocation = ActionInvocation(arguments: ["item": .string(SidebarBuiltIn.chief.rawValue)], origin: .script)
                    _ = registry.perform("sidebar.item.add", invocation: invocation)
                }
                return
            }
        }
    }

    /// Whether to add the Chief now, for a loaded sidebar document that `placed` the Chief or not: true only the
    /// first time, and only when it holds none. Marks the offer made either way.
    public func shouldAdd(placed: Bool) -> Bool {
        guard !defaults.bool(forKey: Self.offeredKey) else { return false }
        defaults.set(true, forKey: Self.offeredKey)
        return !placed
    }
}
