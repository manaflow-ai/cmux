import CmuxSettings
import Foundation
import Observation

@MainActor
@Observable
final class UsageTipsController {
    private enum State {
        case idle
        case waiting
        case presenting(UsageTipPresentation)
        case finished
    }

    private let store: UsageTipsStore
    private let catalog: UsageTipsCatalog
    private let shortcutResolver: UsageTipShortcutResolver
    private let scheduler: UsageTipScheduler
    private let initialDelay: TimeInterval
    private let autoHideDelay: TimeInterval
    private let isEligibleLaunch: Bool
    private var state: State = .idle
    @ObservationIgnored private var tipsEnabled: Bool
    @ObservationIgnored private var registeredWindowIDs: [UUID] = []
    @ObservationIgnored private var activeWindowID: UUID?
    @ObservationIgnored private var cancelInitialTip: UsageTipScheduler.Cancellation?
    @ObservationIgnored private var cancelAutoHide: UsageTipScheduler.Cancellation?

    var presentation: UsageTipPresentation? {
        guard case let .presenting(presentation) = state else { return nil }
        return presentation
    }

    init(
        store: UsageTipsStore,
        catalog: UsageTipsCatalog = UsageTipsCatalog(),
        shortcutResolver: UsageTipShortcutResolver? = nil,
        scheduler: UsageTipScheduler = UsageTipScheduler(),
        initialDelay: TimeInterval = 45,
        autoHideDelay: TimeInterval = 120
    ) {
        self.store = store
        self.catalog = catalog
        self.shortcutResolver = shortcutResolver ?? UsageTipShortcutResolver()
        self.scheduler = scheduler
        self.initialDelay = initialDelay
        self.autoHideDelay = autoHideDelay
        self.isEligibleLaunch = store.hasShownWelcome
        self.tipsEnabled = store.isEnabled
    }

    func register(windowID: UUID) {
        guard !registeredWindowIDs.contains(windowID) else { return }
        registeredWindowIDs.append(windowID)
    }

    func windowDidBecomeKey(windowID: UUID) {
        guard registeredWindowIDs.contains(windowID) else { return }
        activeWindowID = windowID
        scheduleInitialTipIfNeeded()
    }

    func windowDidResignKey(windowID: UUID) {
        guard activeWindowID == windowID else { return }
        activeWindowID = nil
    }

    func unregister(windowID: UUID) {
        registeredWindowIDs.removeAll { $0 == windowID }
        if activeWindowID == windowID {
            activeWindowID = nil
        }
        switch state {
        case .waiting where registeredWindowIDs.isEmpty:
            cancelInitialTip?()
            cancelInitialTip = nil
            state = .idle
        case .presenting(let presentation) where presentation.windowID == windowID:
            finishPresentation()
        default:
            break
        }
    }

    func updateEnabled(_ isEnabled: Bool) {
        tipsEnabled = isEnabled
        guard isEnabled else {
            cancelInitialTip?()
            cancelAutoHide?()
            cancelInitialTip = nil
            cancelAutoHide = nil
            state = .finished
            return
        }
        scheduleInitialTipIfNeeded()
    }

    func acknowledge() {
        guard case let .presenting(presentation) = state else { return }
        store.markSeen(presentation.tip.id.rawValue)
        finishPresentation()
    }

    func dismiss() {
        guard case .presenting = state else { return }
        finishPresentation()
    }

    private func scheduleInitialTipIfNeeded() {
        guard isEligibleLaunch,
              tipsEnabled,
              activeWindowID.map(registeredWindowIDs.contains) == true else { return }
        guard case .idle = state else { return }
        state = .waiting
        cancelInitialTip = scheduler.schedule(after: initialDelay) { [weak self] in
            self?.presentNextTip()
        }
    }

    private func presentNextTip() {
        cancelInitialTip = nil
        guard case .waiting = state else { return }
        guard tipsEnabled, let windowID = registeredWindowIDs.last else {
            state = registeredWindowIDs.isEmpty ? .idle : .finished
            return
        }

        let unseenTips = catalog.unseenTips(seenTipIDs: store.seenTipIDs)
        let presentation = unseenTips.lazy.compactMap { tip -> UsageTipPresentation? in
            guard let shortcutLabel = self.shortcutResolver.displayString(for: tip.shortcutAction) else {
                return nil
            }
            return UsageTipPresentation(tip: tip, shortcutLabel: shortcutLabel, windowID: windowID)
        }.first

        guard let presentation else {
            state = .finished
            return
        }

        state = .presenting(presentation)
        cancelAutoHide = scheduler.schedule(after: autoHideDelay) { [weak self] in
            self?.dismiss()
        }
    }

    private func finishPresentation() {
        cancelAutoHide?()
        cancelAutoHide = nil
        state = .finished
    }
}
