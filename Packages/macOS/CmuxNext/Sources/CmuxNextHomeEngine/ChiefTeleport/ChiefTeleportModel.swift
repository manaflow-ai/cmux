public import Foundation
public import Observation
import CmuxNextCompat

/// Chief teleport's state for every surface that shows it (the Home header's location chip, the
/// Chief card's row): where this Mac's Chief runs (``location``, from its home's `moved.json`), the
/// running or last move (``phase``), and the app's move targets.
///
/// The app makes one at its composition root and wires ``destinations``, ``onMove`` and
/// ``onRollback`` to the `chief.moveTo` and `chief.moveRollback` actions, so a menu pick runs the
/// same path as Cmd-Shift-P and the CLI. The move handler sets ``phase`` and calls ``refresh()``
/// when a move or rollback ends; ``startFollowing()`` reads the marker again on every change of it
/// (a move or rollback from the CLI, the MCP tool or the Chief itself too), so Home follows.
///
/// ```swift
/// let model = ChiefTeleportModel(home: temporaryHome)
/// await model.refresh().value
/// ```
@Observable @MainActor
public final class ChiefTeleportModel {
    /// What the home's `state` folder says (where it went and when, a running move, its fork);
    /// none until the first ``refresh()`` answers.
    public private(set) var marks = ChiefHomeMarks.none
    /// Where the Chief went; This Mac until the first ``refresh()`` answers.
    public var whereabouts: ChiefWhereabouts { marks.whereabouts }
    /// Where the Chief runs.
    public var location: ChiefLocation { whereabouts.location }
    /// The teleport event the Chief chat shows once (``ChiefTeleportAnnouncement``); nil until the app
    /// sees a move or fork happen, and again after ``dismissAnnouncement()``.
    public private(set) var announcement: ChiefTeleportAnnouncement?
    /// Whether the first read answered: its marks are the start, never an event.
    @ObservationIgnored private var hasRead = false
    /// The Chief chat's newest message seq (``endAnnouncementOnNewerMessage(newestSeq:)``); nil until Home wires it.
    @ObservationIgnored private var newestSeq: (@MainActor () -> UInt64)?
    /// The chat's newest seq when ``announcement`` came: the message the row shows under.
    @ObservationIgnored private var announcedAt: UInt64 = 0
    /// Ends ``announcement`` once the Chief chat gets a newer message.
    @ObservationIgnored private var announcementWatch: Task<Void, Never>?
    /// The running or last move started from this app.
    public var phase: ChiefTeleportPhase = .idle
    /// The move the chip, menu and chat row show: this app's while one runs, else a move the
    /// home's hold says runs (from the CLI, the MCP tool or the Chief itself), else this app's last.
    public var shownPhase: ChiefTeleportPhase {
        if phase.isRunning { return phase }
        if let hold = marks.moving { return .moving(Self.placeName(hold.to ?? .cloud, destinations: destinations())) }
        return phase
    }
    /// The Chief home whose marker this model reads.
    @ObservationIgnored public let home: URL
    /// The app's move targets now (`ChiefMoveTargets`); read when a menu opens.
    @ObservationIgnored public var destinations: @MainActor () -> [ChiefTeleportDestination] = { [] }
    /// Moves the Chief to the destination with this id (`chief.moveTo`).
    @ObservationIgnored public var onMove: @MainActor (String) -> Void = { _ in }
    /// Rolls the last move back (`chief.moveRollback`).
    @ObservationIgnored public var onRollback: @MainActor () -> Void = {}
    /// The home was found marked moved: at the first read after launch, and each time a marker
    /// appears or names a new place. The app starts the engine's `move watch` here.
    @ObservationIgnored public var onMoved: @MainActor (ChiefWhereabouts) -> Void = { _ in }
    /// Nil for a model that only shows (``init(showing:phase:destinations:)``).
    @ObservationIgnored private let reader: ChiefLocationReader?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var following: Task<Void, Never>?

    /// - Parameters:
    ///   - home: The Chief home to read (`ChiefHome.resolve(tag:).root`).
    ///   - reader: Reads its marker (tests pass the default with a temporary home).
    public init(home: URL, reader: ChiefLocationReader = ChiefLocationReader()) {
        self.home = home
        self.reader = reader
    }

    /// A model that shows `location` and `phase` and reads nothing (the playground's variants).
    ///
    /// - Parameters:
    ///   - movedAt: When the move to `location` ended.
    ///   - moving: A move the home's hold says runs.
    ///   - fork: The Chief's fork in cmux Cloud.
    public init(showing location: ChiefLocation, phase: ChiefTeleportPhase, destinations: [ChiefTeleportDestination],
                movedAt: Date? = nil, moving: ChiefMoveHold? = nil, fork: ChiefForkRecord? = nil) {
        home = URL(fileURLWithPath: "/dev/null")
        reader = nil
        marks = ChiefHomeMarks(whereabouts: ChiefWhereabouts(location: location, cloudAgentID: nil), movedAt: movedAt, moving: moving, fork: fork)
        // The playground shows each state's row as the moment it happens.
        announcement = phase == .rolledBack ? .movedBack : ChiefTeleportAnnouncement(from: .none, to: marks)
        self.phase = phase
        self.destinations = { destinations }
    }

    /// Reads the home's marker again (off the main thread) and shows what it says; a newer call
    /// replaces a read in flight. A model that only shows reads nothing.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        // task-owner: none; an empty task for a model that only shows.
        guard let reader else { return Task {} }
        reading?.cancel()
        let home = home
        // task-owner: this model (a newer refresh cancels it); one file read, then one assignment.
        let task = Task { [weak self] in
            let marks = await reader.marks(home: home)
            guard !Task.isCancelled, let self else { return }
            let first = !hasRead
            hasRead = true
            // The first read on a home already marked moved still starts the engine's watch (onMoved).
            guard first || self.marks != marks else { return }
            let moved = marks.whereabouts != self.whereabouts
            if !first, let event = ChiefTeleportAnnouncement(from: self.marks, to: marks) {
            announcement = event
            announcedAt = newestSeq?() ?? 0
        }
            self.marks = marks
            if moved, marks.whereabouts.location != .thisMac { onMoved(marks.whereabouts) }
        }
        reading = task
        return task
    }

    /// Follows the home's marker: reads it now and again on every change (``ChiefMovedMarkerWatcher``),
    /// for as long as the model lives. A second call does nothing; a model that only shows follows nothing.
    public func startFollowing() {
        guard reader != nil, following == nil else { return }
        let changes = ChiefMovedMarkerWatcher(home: home).changes()
        // task-owner: this model (it ends at the first change after the model is released); event-driven (a file watch).
        following = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                refresh()
            }
        }
        refresh()
    }

    /// The menu as it is now.
    public func menu() -> ChiefTeleportMenu {
        ChiefTeleportMenu(location: location, destinations: destinations(), phase: shownPhase)
    }

    /// The row in the chat now (``ChiefTeleportNotice``): a running or failed move, else the event
    /// ``announcement`` until it is dismissed; nil when there is none.
    public func notice(timeZone: TimeZone = .current) -> String? {
        let destinations = destinations()
        return ChiefTeleportNotice(phase: shownPhase, announcement: announcement, placeName: { Self.placeName($0, destinations: destinations) })
            .text(timeZone: timeZone)
    }

    /// Ends the event's row (``endAnnouncementOnNewerMessage(newestSeq:)`` calls it when the Chief
    /// chat moves past it: a newer message).
    public func dismissAnnouncement() {
        if announcement != nil { announcement = nil }
    }

    /// Ends each ``announcement`` once the Chief chat gets a message newer than the one it showed
    /// under, so the row shows once, at the moment of the move or fork, and never again.
    ///
    /// - Parameter newestSeq: the newest message's seq in the chats that show the row (Home reads
    ///   it from its store, an `@Observable` read, so a new message wakes the watch).
    public func endAnnouncementOnNewerMessage(newestSeq: @escaping @MainActor () -> UInt64) {
        self.newestSeq = newestSeq
        announcementWatch?.cancel()
        // task-owner: the model (app lifetime); event-driven (Observation of the chat's newest seq).
        announcementWatch = Task { [weak self] in
            for await newest in ObservationStream({ newestSeq() }) {
                guard let self, announcement != nil, newest > announcedAt else { continue }
                dismissAnnouncement()
            }
        }
    }

    /// A place's name as the menu says it (a host's group name), else the chip's own words.
    nonisolated static func placeName(_ location: ChiefLocation, destinations: [ChiefTeleportDestination]) -> String {
        let held = destinations.first { $0.holds(location) && $0.isAvailable }
        return ChiefTeleportChip.placeTitle(location, current: held?.title)
    }
}
