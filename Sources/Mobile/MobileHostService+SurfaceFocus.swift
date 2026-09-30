import CmuxMobileHost
import Foundation

extension MobileHostConnection {
    /// Applies one authorized focus transition through the connection-owned
    /// queue and writer, preserving release-before-priority ordering.
    func noteInteractiveSurface(_ rawSurfaceKey: String) async {
        let surfaceKey = MobileHostConnectionEventQueue.canonicalSurfaceKey(rawSurfaceKey)
        guard !surfaceKey.isEmpty, lastInteractiveSurfaceKey != surfaceKey else { return }
        lastInteractiveSurfaceKey = surfaceKey
        focusTransitionGeneration &+= 1
        let transitionGeneration = focusTransitionGeneration
        guard surfaceEventLanesActive, let independentEventWriter else { return }
        await focusSurfaceLane(
            surfaceKey,
            writer: independentEventWriter,
            transitionGeneration: transitionGeneration
        )
    }

    func focusSurfaceLane(
        _ surfaceKey: String,
        writer: any MobileHostIndependentEventWriting,
        transitionGeneration: UInt64
    ) async {
        let released = eventQueue.focusSurfaceLane(surfaceKey)
        if !released.isEmpty {
            MobileTerminalRenderObserver.requestRenderGridFullResync(
                surfaceIDStrings: Set(released.keys)
            )
            await writer.releaseSurfaceLanes(released)
        }
        guard transitionGeneration == focusTransitionGeneration else { return }
        await writer.noteInteractiveSurface(surfaceKey)
    }
}
