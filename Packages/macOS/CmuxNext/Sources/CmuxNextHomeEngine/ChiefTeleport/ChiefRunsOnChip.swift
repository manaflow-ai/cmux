public import AppKit
import CmuxNextCompat

/// The Chief card's Runs On chip: where this Mac's Chief runs, whose click opens the Teleport menu
/// of the app's one ``ChiefTeleportModel``. Home's header shows no location chip (user 2026-11-20:
/// "This Mac + Cloud fork" sat over the Chief's name there).
///
/// ```swift
/// runsOn.follow(for: self, { service?.showsTeleport(conversation: id) ?? false }) { chip in
///     settingsView.showTeleport(chip)
/// }
/// ```
@MainActor
public final class ChiefRunsOnChip {
    private let chip: ChiefTeleportChip
    private var following: Task<Void, Never>?

    /// - Parameter model: The app's teleport state, which the chip shows.
    public init(model: ChiefTeleportModel) {
        chip = ChiefTeleportChip(model: model)
        chip.setAccessibilityIdentifier("cmux.home.chief.teleport.card")
    }

    /// Places the chip while `shows` is true and takes it away while it is false, each time it changes,
    /// until `owner` is gone.
    /// - Parameters:
    ///   - owner: The view that shows the chip (held weakly): the follow ends at the first change after it is released.
    ///   - shows: Whether this conversation is the Chief `cmux chief move` moves (read under Observation).
    ///   - place: Puts the chip in the card's Runs On row, or nil to take it away.
    public func follow(for owner: AnyObject, _ shows: @escaping @MainActor @Sendable () -> Bool,
                       place: @escaping @MainActor @Sendable (_ chip: ChiefTeleportChip?) -> Void) {
        following?.cancel()
        let chip = chip
        // task-owner: self (cancelled on the next follow); ends at the first change after owner is released; event-driven (Observation)
        following = Task { [weak owner] in
            for await shown in ObservationStream(shows) {
                guard owner != nil else { return }
                place(shown ? chip : nil)
            }
        }
    }
}
