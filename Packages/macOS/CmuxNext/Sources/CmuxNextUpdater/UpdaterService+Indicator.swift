public import CmuxUpdater
public import Foundation

/// The rail's update circle over this service: what it shows, what a
/// click does, and the release notes its menu links.
extension UpdaterService {
    /// The circle's phase: Sparkle's flow, else (no Sparkle) the probe the
    /// user asked for.
    public var indicatorPhase: UpdateIndicatorPhase {
        if let debugIndicatorPhase { return debugIndicatorPhase }
        if let controller, disabledReason == nil {
            let version = controller.stagedUpdate?.displayVersionString ?? controller.model.detectedUpdateVersion
            return UpdateIndicatorPhase(controller.model.effectiveState, version: version)
        }
        guard showsProbeResult else { return .hidden }
        return UpdateIndicatorPhase(probe: lastProbe, error: lastProbeError, probing: isProbing)
    }

    /// A click on the circle: install a waiting or downloading update, or
    /// show a failure's details.
    public func indicatorClicked() {
        switch indicatorPhase {
        case .ready, .downloading:
            try? installAvailableUpdate()
        case .note(_, isError: true):
            presentUpdateUI?()
        case .hidden, .checking, .installing, .note:
            break
        }
    }

    /// The note beside the circle timed out (up to date clears itself).
    public func dismissIndicatorNote() {
        if case .note = debugIndicatorPhase { debugIndicatorPhase = nil }
        showsProbeResult = false
        if let state = controller?.model.effectiveState, case .error = state { state.cancel() }
    }

    /// The release notes for the waiting update, or nil.
    public var indicatorReleaseNotesURL: URL? {
        guard case .ready(let version?) = indicatorPhase else { return nil }
        return UpdateState.ReleaseNotes(displayVersionString: version)?.url
    }
}
