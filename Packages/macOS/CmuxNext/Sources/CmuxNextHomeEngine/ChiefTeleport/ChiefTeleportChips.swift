public import AppKit
import CmuxNextCompat

/// A Home conversation's Chief location chip: the Chief card's Runs On row, whose Teleport menu
/// moves the app's one ``ChiefTeleportModel``. The Home header shows no location chip (cmux issue
/// 36047): where the Chief runs is part of the Chief, so it lives in the card the name pill opens.
///
/// ```swift
/// teleportChips.follow(for: self, { service?.showsTeleport(conversation: id) ?? false }) { card in
///     settingsView.showTeleport(card)
/// }
/// ```
@MainActor
public final class ChiefTeleportChips {
    private let card: ChiefTeleportChip
    private var following: Task<Void, Never>?

    /// - Parameter model: The app's teleport state, which the chip shows.
    public init(model: ChiefTeleportModel) {
        card = ChiefTeleportChip(model: model)
        card.setAccessibilityIdentifier("cmux.home.chief.teleport.card")
    }

    /// Places the chip while `shows` is true and takes it away while it is false, each time it changes,
    /// until `owner` is gone.
    /// - Parameters:
    ///   - owner: The view that shows the chip (held weakly): the follow ends at the first change after it is released.
    ///   - shows: Whether this conversation is the Chief `cmux chief move` moves (read under Observation).
    ///   - place: Puts the card chip in its place, or nil to take it away.
    public func follow(for owner: AnyObject, _ shows: @escaping @MainActor @Sendable () -> Bool,
                       place: @escaping @MainActor @Sendable (_ card: ChiefTeleportChip?) -> Void) {
        following?.cancel()
        let card = card
        // task-owner: self (cancelled on the next follow); ends at the first change after owner is released; event-driven (Observation)
        following = Task { [weak owner] in
            for await shown in ObservationStream(shows) {
                guard owner != nil else { return }
                place(shown ? card : nil)
            }
        }
    }
}
