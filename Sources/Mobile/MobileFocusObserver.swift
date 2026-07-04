import Combine
import Foundation
import OSLog

private let mobileFocusObserverLog = Logger(subsystem: "dev.cmux", category: "mobile-focus-observer")

/// Emits `focus.updated` events to mobile clients when the Mac's focused pane changes.
@MainActor
final class MobileFocusObserver {
    private weak var tabManager: TabManager?
    private var focusSurfaceCancellable: AnyCancellable?
    private var focusTabCancellable: AnyCancellable?
    private var selectionCancellable: AnyCancellable?
    private var activeManagerCancellable: AnyCancellable?
    private var lastSummaryHash = 0
    private let throttleMilliseconds = 50

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        attach(to: tabManager)
    }

    private func attach(to tabManager: TabManager) {
        lastSummaryHash = MobileFocusSnapshotPayload.snapshot(tabManager: tabManager).summaryHash
        emitIfNeeded(force: true)

        focusSurfaceCancellable = NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        focusTabCancellable = NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        selectionCancellable = tabManager.selectedTabIdPublisher
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        activeManagerCancellable = NotificationCenter.default.publisher(for: TerminalController.activeTabManagerDidChangeNotification)
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.emitIfNeeded(force: true)
            }
    }

    private func emitIfNeeded(force: Bool) {
        guard let tabManager else { return }
        guard tabManager === TerminalController.shared.activeTabManagerForCallerNotification() else { return }
        let snapshot = MobileFocusSnapshotPayload.snapshot(tabManager: tabManager)
        let hash = snapshot.summaryHash
        guard force || hash != lastSummaryHash else { return }
        lastSummaryHash = hash
        mobileFocusObserverLog.debug("emitting focus.updated (hash=\(hash, privacy: .public))")
        MobileHostService.shared.emitEvent(topic: "focus.updated", payload: snapshot.jsonObject())
    }
}
