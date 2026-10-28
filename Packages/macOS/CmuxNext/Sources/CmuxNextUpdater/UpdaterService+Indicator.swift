public import CmuxUpdater
public import Foundation
@preconcurrency import Sparkle

/// The rail's update circle over this service: what it shows, what a
/// click does, and the release notes its menu links.
extension UpdaterService {
    /// The circle's phase: Sparkle's flow, else (no Sparkle) the probe the
    /// user asked for. A staged update that is not newer than the running
    /// build is no update (``offersStagedUpdate(version:)``).
    public var indicatorPhase: UpdateIndicatorPhase {
        let phase = sourcePhase
        if case .ready(let version) = phase, !offersStagedUpdate(version: version) { return .hidden }
        return phase
    }

    var sourcePhase: UpdateIndicatorPhase {
        if let debugIndicatorPhase { return debugIndicatorPhase }
        if let controller, disabledReason == nil {
            let version = controller.stagedUpdate?.displayVersionString ?? controller.model.detectedUpdateVersion
            return UpdateIndicatorPhase(controller.model.effectiveState, version: version)
        }
        guard showsProbeResult else { return .hidden }
        return UpdateIndicatorPhase(probe: lastProbe, error: lastProbeError, probing: isProbing)
    }

    /// Whether a staged update is newer than the running app (Leo 2026-10-20:
    /// never offer the version already running). Sparkle resumes an installer
    /// still finishing after the relaunch, or a download it kept, as "Restart to
    /// Complete Update" for the build that now runs, sometimes with no item.
    /// The staged `sparkle:version` decides against `CFBundleVersion`; without
    /// one, a display version other than the running one; with neither, it is
    /// unknown and not offered.
    func offersStagedUpdate(version: String?) -> Bool {
        if let build = stagedBuild(), !build.isEmpty {
            return SUStandardVersionComparator.default.compareVersion(build, toVersion: identity.build) == .orderedDescending
        }
        guard let version, !version.isEmpty else { return false }
        return version != identity.shortVersion
    }

    /// The update sheet closed (set by the App): the tip app's feed read resumes (``TipUpdateCheck``).
    public func updateSheetClosed() {
        tipCheck.refresh(self)
        followReleasePush()
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
}
