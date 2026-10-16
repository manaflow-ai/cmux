#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Observes native scroll phases without replacing gestures or the List delegate.
struct AgentFeedPerformanceModifier: ViewModifier {
    let observer: (any MobileFeedPerformanceObserving)?
    let isActive: Bool
    let itemCount: Int
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.scrollInteractionReporter) private var replayInteraction
    @State private var monitor: AgentFeedScrollMonitor
    @State private var pausesReplay = false

    init(observer: (any MobileFeedPerformanceObserving)?, isActive: Bool, itemCount: Int) {
        self.observer = observer
        self.isActive = isActive
        self.itemCount = itemCount
        _monitor = State(initialValue: AgentFeedScrollMonitor(observer: observer))
    }

    func body(content: Content) -> some View {
        observed(content)
            .onAppear { updateVisibility() }
            .onChange(of: isActive) { _, _ in updateVisibility() }
            .onChange(of: scenePhase) { _, _ in updateVisibility() }
            .onChange(of: itemCount) { _, _ in updateVisibility() }
            .onDisappear {
                settle()
                observer?.setVisible(false, itemCount: itemCount)
            }
    }

    @ViewBuilder private func observed(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                guard isActive, scenePhase == .active else { return }
                let moving = phase == .interacting || phase == .decelerating
                // Resume replay before the reporter emits a settled anomaly.
                setReplayPaused(phase != .idle)
                monitor.setScrolling(moving)
            }
        } else {
            // iOS 17 still reports Feed update stages, but has no native phase hook.
            content
        }
    }

    private func updateVisibility() {
        let visible = isActive && scenePhase == .active
        if !visible { settle() }
        observer?.setVisible(visible, itemCount: itemCount)
    }

    private func settle() {
        setReplayPaused(false)
        monitor.stop()
    }

    private func setReplayPaused(_ paused: Bool) {
        guard pausesReplay != paused else { return }
        pausesReplay = paused
        replayInteraction?.interactionChanged(paused)
    }
}
#endif
