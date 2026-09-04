import Foundation
import SwiftUI

/// Immutable liveness inputs shared by the main Vault table and paginated
/// popovers. Keeping the key snapshot together with its timestamp means a
/// page can derive the same status for entries that were not in the initial
/// section projection.
struct SessionIndexStatusSnapshot: Equatable, Sendable {
    let activeSessionKeys: Set<String>
    let liveSessionKeys: Set<String>
    let now: Date

    init(
        activeSessionKeys: Set<String> = [],
        liveSessionKeys: Set<String> = [],
        now: Date = .now
    ) {
        self.activeSessionKeys = activeSessionKeys
        self.liveSessionKeys = liveSessionKeys
        self.now = now
    }

    func containsActivePaneSession(_ entry: SessionEntry) -> Bool {
        activeSessionKeys.contains(VaultLiveSessionKeys.key(for: entry))
    }

    func accessory(
        for entry: SessionEntry,
        includeDetail: Bool = false
    ) -> VaultSessionRowAccessory {
        VaultSessionRowAccessory.make(
            for: entry,
            liveKeys: liveSessionKeys,
            now: now,
            includeDetail: includeDetail
        )
    }

    func presentation(
        for entry: SessionEntry,
        includeDetail: Bool = false
    ) -> (accessory: VaultSessionRowAccessory, isActive: Bool) {
        (
            accessory: accessory(for: entry, includeDetail: includeDetail),
            isActive: containsActivePaneSession(entry)
        )
    }
}

/// Immutable presentation state for the status circle shown beside a Vault
/// session. The private state enum keeps the active flag and accessibility
/// label derived from one source instead of allowing contradictory values.
struct SessionIndexStatusIndicatorModel: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case activeInPane
        case active
        case inactive
    }

    private let state: State

    private init(state: State) {
        self.state = state
    }

    var isActive: Bool {
        switch state {
        case .activeInPane, .active:
            return true
        case .inactive:
            return false
        }
    }

    var label: String {
        switch state {
        case .activeInPane:
            return String(
                localized: "sessionIndex.status.activeInPane",
                defaultValue: "Active in pane"
            )
        case .active:
            return String(
                localized: "sessionIndex.status.activeIndicator",
                defaultValue: "Active"
            )
        case .inactive:
            return String(
                localized: "sessionIndex.status.inactiveIndicator",
                defaultValue: "Inactive"
            )
        }
    }

    var color: Color {
        isActive ? .green : Color.secondary.opacity(0.55)
    }

    /// In-pane sessions stay active even if their process is currently idle.
    /// Indexed rows use the recent-activity status when it is available.
    nonisolated static func make(
        isInPane: Bool,
        liveStatus: VaultSessionLiveStatus?
    ) -> SessionIndexStatusIndicatorModel {
        if isInPane {
            return SessionIndexStatusIndicatorModel(state: .activeInPane)
        }
        if liveStatus?.isActiveForIndicator == true {
            return SessionIndexStatusIndicatorModel(state: .active)
        }
        return SessionIndexStatusIndicatorModel(state: .inactive)
    }
}

/// Shared 6×6 status circle used by full Vault rows and their popovers.
struct SessionStatusIndicator: View {
    let model: SessionIndexStatusIndicatorModel

    init(isInPane: Bool, liveStatus: VaultSessionLiveStatus?) {
        model = .make(isInPane: isInPane, liveStatus: liveStatus)
    }

    var body: some View {
        Circle()
            .fill(model.color)
            .frame(width: 6, height: 6)
            .help(model.label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(model.label))
    }
}
