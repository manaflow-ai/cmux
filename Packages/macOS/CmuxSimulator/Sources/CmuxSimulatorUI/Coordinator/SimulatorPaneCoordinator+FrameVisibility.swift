import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Applies the pane's host visibility to every resource that should stop
    /// work while the Simulator is occluded.
    public func setPaneVisibility(_ isVisible: Bool) {
        paneIsVisible = isVisible
        applyEffectivePaneVisibility()
    }

    func setHostWindowVisibility(_ isVisible: Bool) {
        setHostWindowVisibility(isVisible, for: legacyHostWindowVisibilityObserverID)
    }

    func setHostWindowVisibility(_ isVisible: Bool, for observerID: UUID) {
        guard hostWindowVisibilityByObserverID[observerID] != isVisible else { return }
        hostWindowVisibilityByObserverID[observerID] = isVisible
        applyObservedHostWindowVisibility()
    }

    func removeHostWindowVisibilityObserver(_ observerID: UUID) {
        guard hostWindowVisibilityByObserverID.removeValue(forKey: observerID) != nil else {
            return
        }
        applyObservedHostWindowVisibility()
    }

    private func applyObservedHostWindowVisibility() {
        let isVisible = hostWindowVisibilityByObserverID.values.contains(true)
        guard hostWindowIsVisible != isVisible else { return }
        hostWindowIsVisible = isVisible
        applyEffectivePaneVisibility()
    }

    var effectivePaneIsVisible: Bool {
        paneIsVisible && hostWindowIsVisible
    }

    private func applyEffectivePaneVisibility() {
        let isVisible = effectivePaneIsVisible
        setAccessibilityOverlayVisibility(isVisible)
        setLiveStatusVisibility(isVisible && showsTools)
        setFrameVisibility(isVisible)
    }

    /// Registers a mobile framebuffer consumer independently from AppKit pane
    /// visibility. Re-registering an existing consumer also reconciles a lost
    /// transport, which is required after worker or shared-memory replacement.
    public func setMobileFrameDemand(_ active: Bool, consumerID: UUID) {
        if active {
            mobileFrameConsumerIDs.insert(consumerID)
        } else {
            mobileFrameConsumerIDs.remove(consumerID)
        }
        reconcileFramePublication(forceIfMissing: active)
    }

    /// Reconciles local pane demand with mobile demand. Device control and
    /// inspection remain attached when no framebuffer consumer is active.
    public func setFrameVisibility(_ isVisible: Bool) {
        localFrameDemand = isVisible
        reconcileFramePublication()
    }

    /// The coordinator owns both desired publication and observed transport.
    /// An unchanged demand bit is not proof that shared memory still exists.
    func reconcileFramePublication(forceIfMissing: Bool = false) {
        let shouldPublish = localFrameDemand || !mobileFrameConsumerIDs.isEmpty
        let demandChanged = frameIsVisible != shouldPublish
        frameIsVisible = shouldPublish
        if !shouldPublish { frameTransport = nil }
        guard status == .streaming else { return }
        guard demandChanged
                || (forceIfMissing && (!shouldPublish || frameTransport == nil)) else {
            return
        }
        enqueue(.setFramebufferPublishing(shouldPublish))
    }
}
