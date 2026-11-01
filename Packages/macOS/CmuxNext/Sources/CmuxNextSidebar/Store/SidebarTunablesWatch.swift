import AppKit
import Observation

/// The sidebar tunables workspace rows draw from (agent mark, presence dots,
/// row badge, stack size, quiet unnamed rows, the row name),
/// observed once for every row. Each `WorkspaceRowView.configure` used to arm
/// its own observation, so every status tick left one more registration
/// behind; now a change redraws the live rows from one registration.
@MainActor
final class SidebarTunablesWatch {
    static let shared = SidebarTunablesWatch()

    typealias Values = (agentMark: SidebarAgentMarkVariant, presenceDots: Bool, rowBadge: SidebarRowBadgeStyle, stackCap: SidebarRowBadgeStackCap, workspaceTitleMotion: SidebarWorkspaceTitleMotionVariant, quietUnnamedRows: Bool,
                         rowTitle: SidebarRowTitleMode, rowTitleSingleChat: Bool)

    /// Every tunable a listed row draws or lays out from, read together so one pass can tell whether any changed.
    private struct Snapshot: Equatable {
        var agentMark: SidebarAgentMarkVariant, presenceDots: Bool, rowBadge: SidebarRowBadgeStyle, stackCap: SidebarRowBadgeStackCap
        var workspaceTitleMotion: SidebarWorkspaceTitleMotionVariant, quietUnnamedRows: Bool
        var rowTitle: SidebarRowTitleMode, rowTitleSingleChat: Bool
        /// Laid out, not configured: the hover close's spot and glyph size.
        var rowCloseSpot: SidebarRowCloseSpot

        static func read() -> Snapshot {
            Snapshot(agentMark: SidebarTunables.agentMark.value, presenceDots: SidebarTunables.presenceDots.value,
                     rowBadge: SidebarRowBadgeStyle.tunable.value, stackCap: SidebarRowBadgeStackCap.tunable.value,
                     workspaceTitleMotion: SidebarTunables.workspaceTitleMotion.value, quietUnnamedRows: SidebarTunables.quietUnnamedRows.value,
                     rowTitle: SidebarTunables.rowTitle.value, rowTitleSingleChat: SidebarTunables.rowTitleSingleChat.value,
                     rowCloseSpot: SidebarTunables.rowCloseSpot.value)
        }

        var values: Values {
            (agentMark, presenceDots, rowBadge, stackCap, workspaceTitleMotion, quietUnnamedRows, rowTitle, rowTitleSingleChat)
        }
    }

    private let rows = NSHashTable<WorkspaceRowView>.weakObjects()
    /// The values the live rows drew with; nil until a row first asks.
    private var snapshot: Snapshot?
    /// An observation is registered and has not fired yet (its hop to `fired()` is not done).
    private var armed = false

    /// The current values; `row` is redrawn when one changes.
    func values(for row: WorkspaceRowView) -> Values {
        rows.add(row)
        return current().values
    }

    /// Redraws the live rows when a tunable they read differs from what they drew with. The observation runs this
    /// one main-actor hop after a change; a test that sets a tunable and draws a row in the same turn calls it right
    /// after the set. A pass that finds nothing new returns without touching a row: one set used to run three full
    /// passes over every live row in the process (two observations and the test's own call), which stalled
    /// whole-process test runs on the main thread until the watchdog killed them.
    func changed() {
        guard let drawn = snapshot else { return } // no row has drawn yet
        let now = refresh()
        guard now != drawn else { return }
        for row in rows.allObjects {
            row.redrawLastConfiguration()
            // `sidebar.rowCloseSpot` changes no configuration: lay the controls out again (the close re-renders its glyph).
            row.needsLayout = true
            row.closeButton.needsLayout = true
        }
    }

    private func current() -> Snapshot {
        snapshot ?? refresh()
    }

    /// Reads the values into `snapshot`, registering the one observation when none is pending.
    private func refresh() -> Snapshot {
        let now: Snapshot
        if armed {
            now = Snapshot.read()
        } else {
            armed = true
            now = withObservationTracking {
                Snapshot.read()
            } onChange: {
                Task { @MainActor in SidebarTunablesWatch.shared.fired() }
            }
        }
        snapshot = now
        return now
    }

    /// The observation's hop: `changed()` reads the values again, which registers the next observation.
    private func fired() {
        armed = false
        changed()
    }
}
