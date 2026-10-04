public import CmuxUpdater
public import Foundation
@preconcurrency import Sparkle

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
            installClicked()
        case .note(_, isError: true):
            presentUpdateUI?()
        case .hidden, .checking, .installing, .note:
            break
        }
    }

    /// The note beside the circle timed out (up to date clears itself).
    public func dismissIndicatorNote() {
        // Sparkle's error is what the open sheet shows; a probe's sheet reads
        // the probe itself, so its note always clears.
        guard controller == nil || !isSheetPresented() else { return }
        if case .note = debugIndicatorPhase { debugIndicatorPhase = nil }
        showsProbeResult = false
        if let state = controller?.model.effectiveState, case .error = state { state.cancel() }
        noteExpired()
    }

    /// Whether a check or install opens the sheet instead of relying on the
    /// circle: the managed explanation, a required minimum version (no
    /// Later), or no circle on screen (window rail off).
    var needsSheet: Bool {
        disabledReason == .managedPolicy || requiredMinimumVersion != nil || !showsIndicator()
    }

    /// The release notes for the waiting update, or nil.
    public var indicatorReleaseNotesURL: URL? {
        guard case .ready(let version?) = indicatorPhase else { return nil }
        return UpdateState.ReleaseNotes(displayVersionString: version)?.url
    }
}
