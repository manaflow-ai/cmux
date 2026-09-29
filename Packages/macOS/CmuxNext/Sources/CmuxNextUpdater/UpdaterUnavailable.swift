import CmuxUpdater

/// Why an update action cannot run in this build.
nonisolated public struct UpdaterUnavailable: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(reason: UpdateDisabledReason?) {
        description = switch reason {
        case .developmentBuild: UpdaterStrings.disabledDevelopment
        case .missingPublicKey: UpdaterStrings.disabledMissingKey
        case .managedPolicy: UpdaterStrings.disabledManaged
        case nil: UpdaterStrings.disabledUnknown
        }
    }

    private init(description: String) {
        self.description = description
    }

    static func cannotSwitch(to target: AppChannelSwitchTarget, from track: UpdateTrack) -> UpdaterUnavailable {
        cannotSwitch(to: target.rawValue, from: track)
    }

    static func cannotSwitch(to target: String, from track: UpdateTrack) -> UpdaterUnavailable {
        UpdaterUnavailable(description: UpdaterStrings.cannotSwitch(to: target, from: track.rawValue))
    }
}
