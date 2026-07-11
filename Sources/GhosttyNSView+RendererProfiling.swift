import Foundation
import CmuxTerminal
import CmuxTerminalCore
import AppKit
import QuartzCore
import os

extension GhosttyNSView {
    func enqueueRenderedFrameUpdate() {
        let profilingEnabled = rendererProfilingSignposts.isEnabled
        let deliveryPolicy = TerminalRenderedFrameDeliveryPolicy(
            renderDemandActive: GhosttyApp.renderedFrameNotificationDemand.isActive
        )
        guard deliveryPolicy.shouldEnqueue(profilingEnabled: profilingEnabled) else { return }

        _renderedFrameLock.lock()
        rendererProfilingCoalescedUpdateCount += 1
        let needsSchedule = !_renderedFrameFlushScheduled
        if needsSchedule {
            _renderedFrameFlushScheduled = true
        }
        _renderedFrameLock.unlock()

        guard needsSchedule else { return }
        if profilingEnabled, let metadata = rendererProfilingMetadata(coalescedUpdateCount: 1) {
            rendererProfilingUpdateState = rendererProfilingSignposts.beginUpdate(metadata)
        }
        DispatchQueue.main.async { [weak self] in
            self?.flushRenderedFrameUpdate()
        }
    }

    private func flushRenderedFrameUpdate() {
        _renderedFrameLock.lock()
        _renderedFrameFlushScheduled = false
        let coalescedUpdateCount = rendererProfilingCoalescedUpdateCount
        rendererProfilingCoalescedUpdateCount = 0
        let profilingState = rendererProfilingUpdateState
        rendererProfilingUpdateState = nil
        _renderedFrameLock.unlock()

        if let metadata = rendererProfilingMetadata(coalescedUpdateCount: coalescedUpdateCount) {
            rendererProfilingSignposts.endUpdate(profilingState, metadata)
        }
        guard GhosttyApp.renderedFrameNotificationDemand.isActive else { return }
        NotificationCenter.default.post(
            name: .ghosttyDidRenderFrame,
            object: self
        )
    }

    private func rendererProfilingMetadata(
        coalescedUpdateCount: Int
    ) -> TerminalRendererProfilingMetadata? {
        guard let terminalSurface else { return nil }
        return TerminalRendererProfilingMetadata(
            identity: terminalSurface.rendererProfilingIdentity,
            visible: isVisibleInUI,
            focused: desiredFocus,
            wakeReason: .terminalOutput,
            coalescedUpdateCount: coalescedUpdateCount,
            dirtyRowCount: nil,
            fullRedraw: nil
        )
    }

    func updateRendererProfilingState(
        wakeReason: TerminalRendererProfilingWakeReason
    ) {
        (layer as? GhosttyMetalLayer)?.setProfilingState(
            identity: terminalSurface?.rendererProfilingIdentity,
            visible: isVisibleInUI,
            focused: desiredFocus,
            wakeReason: wakeReason
        )
    }
}
