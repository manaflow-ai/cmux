public import Foundation
public import Observation

/// Chief teleport's state for every surface that shows it (the Home header's location chip, the
/// Chief card's row): where this Mac's Chief runs (``location``, from its home's `moved.json`), the
/// running or last move (``phase``), and the app's move targets.
///
/// The app makes one at its composition root and wires ``destinations``, ``onMove`` and
/// ``onRollback`` to the `chief.moveTo` and `chief.moveRollback` actions, so a menu pick runs the
/// same path as Cmd-Shift-P and the CLI. The move handler sets ``phase`` and calls ``refresh()``
/// when a move or rollback ends.
///
/// ```swift
/// let model = ChiefTeleportModel(home: temporaryHome)
/// await model.refresh().value
/// ```
@Observable @MainActor
public final class ChiefTeleportModel {
    /// Where the Chief runs; This Mac until the first ``refresh()`` answers.
    public private(set) var location: ChiefLocation = .thisMac
    /// The running or last move.
    public var phase: ChiefTeleportPhase = .idle
    /// The Chief home whose marker this model reads.
    @ObservationIgnored public let home: URL
    /// The app's move targets now (`ChiefMoveTargets`); read when a menu opens.
    @ObservationIgnored public var destinations: @MainActor () -> [ChiefTeleportDestination] = { [] }
    /// Moves the Chief to the destination with this id (`chief.moveTo`).
    @ObservationIgnored public var onMove: @MainActor (String) -> Void = { _ in }
    /// Rolls the last move back (`chief.moveRollback`).
    @ObservationIgnored public var onRollback: @MainActor () -> Void = {}
    /// Nil for a model that only shows (``init(showing:phase:destinations:)``).
    @ObservationIgnored private let reader: ChiefLocationReader?
    @ObservationIgnored private var reading: Task<Void, Never>?

    /// - Parameters:
    ///   - home: The Chief home to read (`ChiefHome.resolve(tag:).root`).
    ///   - reader: Reads its marker (tests pass the default with a temporary home).
    public init(home: URL, reader: ChiefLocationReader = ChiefLocationReader()) {
        self.home = home
        self.reader = reader
    }

    /// A model that shows `location` and `phase` and reads nothing (the playground's variants).
    public init(showing location: ChiefLocation, phase: ChiefTeleportPhase, destinations: [ChiefTeleportDestination]) {
        home = URL(fileURLWithPath: "/dev/null")
        reader = nil
        self.location = location
        self.phase = phase
        self.destinations = { destinations }
    }

    /// Reads the home's marker again (off the main thread) and shows what it says; a newer call
    /// replaces a read in flight. A model that only shows reads nothing.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        guard let reader else { return Task {} }
        reading?.cancel()
        let home = home
        // task-owner: this model (a newer refresh cancels it); one file read, then one assignment.
        let task = Task { [weak self] in
            let location = await reader.read(home: home)
            guard !Task.isCancelled, let self, self.location != location else { return }
            self.location = location
        }
        reading = task
        return task
    }

    /// The menu as it is now.
    public func menu() -> ChiefTeleportMenu {
        ChiefTeleportMenu(location: location, destinations: destinations(), phase: phase)
    }
}
