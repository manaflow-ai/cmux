import CmuxNextHomeEngine

/// A "Move Chief To…" target's words and its Teleport menu row: Cmd-Shift-P, the Home header's
/// location chip and the Chief card list the same targets, by the same names, with the same ids.
extension ChiefMoveTarget {
    /// The target's name: This Mac, cmux Cloud or the host's group name.
    var displayName: String {
        switch kind {
        case .local: WorkspaceVerbStrings.thisMac
        case .cloud: ChiefMoveStrings.cloud
        case .ssh, .server: name
        }
    }

    /// The name with why it is greyed out, when it is ("gcp-linux-1 (offline)").
    var title: String {
        switch disabledReason {
        case nil: displayName
        case .offline: ChiefMoveStrings.offline(displayName)
        case .noSSHRoute: ChiefMoveStrings.noSSHRoute(displayName)
        case .signInNeeded: ChiefMoveStrings.signIn(displayName)
        }
    }

    /// The Teleport menu's row for this target (its id is the `chief.moveTo` target).
    var teleportDestination: ChiefTeleportDestination {
        let place: ChiefTeleportDestination.Place = switch kind {
        case .local: .thisMac
        case .cloud: .cloud
        case .ssh(let destination): .host(destination)
        case .server(let destination): .host(destination ?? name)
        }
        return ChiefTeleportDestination(id: machineID, title: title, place: place, isAvailable: disabledReason == nil && to != nil)
    }
}
