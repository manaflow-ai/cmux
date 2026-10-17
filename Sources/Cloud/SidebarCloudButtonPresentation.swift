import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// What the sidebar footer's Cloud entry says at a glance: the word "Cloud",
/// how many machines are running, and at most one small mark.
///
/// The mark is the attention dot when a machine's status needs the person
/// (the same rule the Machines tree uses for its amber rows), otherwise a
/// one-time accent dot introducing Cloud to someone who has never opened it
/// and has no machines. Showing the Cloud panel once, by any path, retires the
/// introduction for good (``recordCloudOpened(defaults:)``), so the footer
/// never nags.
struct SidebarCloudButtonPresentation: Equatable {
    enum Mark: Equatable {
        case quiet
        /// A machine reports a status that is neither ready nor starting.
        case attention
        /// The Cloud panel has never been shown and there are no machines.
        case introduction
    }

    /// Persists that the person has opened the Cloud panel at least once.
    static let introductionSeenKey = "sidebar.cloud.introductionSeen"

    /// Records that the Cloud panel was shown, retiring the footer's
    /// introduction dot. The one write for every path that shows the panel:
    /// the footer button, the right sidebar's mode button, its shortcut, the
    /// command palette, menus and socket reveals all mount
    /// `MachinesPanelView`, which calls this when it appears. The footer
    /// reads the key through `@AppStorage`, so the dot clears in the same turn.
    /// - Parameter defaults: The store the footer reads; `.standard` in the app.
    @MainActor
    static func recordCloudOpened(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: introductionSeenKey) else { return }
        defaults.set(true, forKey: introductionSeenKey)
    }

    let runningCount: Int
    let mark: Mark

    static func resolve(machines: some Collection<SurfaceMachineInfo>, hasOpenedCloud: Bool) -> Self {
        var cloudMachineCount = 0
        var runningCount = 0
        var needsAttention = false
        for machine in machines where machine.id.cloudMachineID != nil {
            cloudMachineCount += 1
            switch MachineSnapshotBuilder.activity(fromStatus: machine.status) {
            case .ready:
                // Paused and standby machines are listed but cost nothing and
                // do not count, matching the Machines header.
                if ["running", "ready"].contains(machine.status.lowercased()) { runningCount += 1 }
            case .pending:
                break
            case .attention:
                needsAttention = true
            }
        }
        let mark: Mark = if needsAttention {
            .attention
        } else if !hasOpenedCloud, cloudMachineCount == 0 {
            .introduction
        } else {
            .quiet
        }
        return Self(runningCount: runningCount, mark: mark)
    }

    /// The compact count beside the label, or nil when nothing is running.
    var countText: String? {
        runningCount > 0 ? runningCount.formatted(.number) : nil
    }

    /// The tooltip: what the button opens, then the status it summarizes.
    var help: String {
        switch mark {
        case .attention:
            return String(localized: "sidebar.cloud.button.help.attention", defaultValue: "Cloud · A machine needs attention")
        case .introduction:
            return String(localized: "sidebar.cloud.button.help.introduction", defaultValue: "Cloud · Run agents on machines that stay on")
        case .quiet:
            guard runningCount > 0 else {
                return String(localized: "sidebar.cloud.button.help.idle", defaultValue: "Cloud machines")
            }
            return String(
                format: String(localized: "sidebar.cloud.button.help.running", defaultValue: "Cloud · %ld running"),
                runningCount
            )
        }
    }

    /// VoiceOver's value for the button, so the status is not visual-only.
    var accessibilityValue: String {
        var parts: [String] = []
        if runningCount > 0 {
            parts.append(String(
                format: String(localized: "sidebar.cloud.button.value.running", defaultValue: "%ld running"),
                runningCount
            ))
        }
        if mark == .attention {
            parts.append(String(localized: "sidebar.cloud.button.value.attention", defaultValue: "A machine needs attention"))
        }
        return parts.joined(separator: ", ")
    }
}
