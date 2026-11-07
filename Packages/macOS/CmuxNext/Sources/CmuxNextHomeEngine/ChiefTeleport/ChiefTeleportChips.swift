public import AppKit
import CmuxNextCompat

/// A Home conversation's two Chief location chips: the one beside the Chief's name in the header
/// (which says "Chief is on HOST" when Home cannot open the Chief there) and the Chief card's
/// Runs On row. Both open the Teleport menu of the app's one ``ChiefTeleportModel``.
///
/// ```swift
/// teleportChips.follow(for: self, { service?.showsTeleport(conversation: id) ?? false }) { header, card in
///     transcript.headerPillAccessory = header
///     settingsView.showTeleport(card)
/// }
/// ```
@MainActor
public final class ChiefTeleportChips {
    private let header: ChiefTeleportChip
    private let card: ChiefTeleportChip
    private var following: Task<Void, Never>?

    /// - Parameter model: The app's teleport state, which both chips show.
    public init(model: ChiefTeleportModel) {
        header = ChiefTeleportChip(model: model)
        header.setAccessibilityIdentifier("cmux.home.chief.teleport.header")
        header.saysAway = true
        card = ChiefTeleportChip(model: model)
        card.setAccessibilityIdentifier("cmux.home.chief.teleport.card")
    }

    /// Places the chips while `shows` is true and takes them away while it is false, each time it changes,
    /// until `owner` is gone.
    /// - Parameters:
    ///   - owner: The view that shows the chips (held weakly): the follow ends at the first change after it is released.
    ///   - shows: Whether this conversation is the Chief `cmux chief move` moves (read under Observation).
    ///   - place: Puts the header chip and the card chip in their places, or nil to take them away.
    public func follow(for owner: AnyObject, _ shows: @escaping @MainActor @Sendable () -> Bool,
                       place: @escaping @MainActor @Sendable (_ header: ChiefTeleportChip?, _ card: ChiefTeleportChip?) -> Void) {
        following?.cancel()
        let (header, card) = (header, card)
        // task-owner: self (cancelled on the next follow); ends at the first change after owner is released; event-driven (Observation)
        following = Task { [weak owner] in
            for await shown in ObservationStream(shows) {
                guard owner != nil else { return }
                place(shown ? header : nil, shown ? card : nil)
            }
        }
    }
}
