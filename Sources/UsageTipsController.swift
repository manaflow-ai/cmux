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
    private let initialDelay: TimeInterval
    private let autoHideDelay: TimeInterval
    private let isEligibleLaunch: Bool
    private var state: State = .idle
    private var tipsEnabled: Bool
    private var registeredWindowIDs: [UUID] = []
    @ObservationIgnored private var initialTimer: Timer?
    @ObservationIgnored private var autoHideTimer: Timer?

    var presentation: UsageTipPresentation? {
        guard case let .presenting(presentation) = state else { return nil }
        return presentation
    }

    init(
        store: UsageTipsStore,
        catalog: UsageTipsCatalog = UsageTipsCatalog(),
        shortcutResolver: UsageTipShortcutResolver? = nil,
        initialDelay: TimeInterval = 45,
        autoHideDelay: TimeInterval = 120
    ) {
        self.store = store
        self.catalog = catalog
        self.shortcutResolver = shortcutResolver ?? UsageTipShortcutResolver()
        self.initialDelay = initialDelay
        self.autoHideDelay = autoHideDelay
        self.isEligibleLaunch = store.hasShownWelcome
        self.tipsEnabled = store.isEnabled
    }

    func register(windowID: UUID) {
        guard !registeredWindowIDs.contains(windowID) else { return }
        registeredWindowIDs.append(windowID)
        scheduleInitialTipIfNeeded()
    }

    func unregister(windowID: UUID) {
        registeredWindowIDs.removeAll { $0 == windowID }
        switch state {
        case .waiting where registeredWindowIDs.isEmpty:
            initialTimer?.invalidate()
            initialTimer = nil
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
            initialTimer?.invalidate()
            autoHideTimer?.invalidate()
            initialTimer = nil
            autoHideTimer = nil
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
        guard isEligibleLaunch, tipsEnabled, !registeredWindowIDs.isEmpty else { return }
        guard case .idle = state else { return }
        state = .waiting
        // A one-shot Timer models the intended presentation deadline without sleeping or polling.
        initialTimer = makeTimer(after: initialDelay) { [weak self] in
            self?.presentNextTip()
        }
    }

    private func presentNextTip() {
        initialTimer = nil
        guard case .waiting = state else { return }
        guard tipsEnabled, let windowID = registeredWindowIDs.last else {
            state = registeredWindowIDs.isEmpty ? .idle : .finished
            return
        }

        let unseenTips = catalog.unseenTips(seenTipIDs: store.seenTipIDs)
        let presentation = unseenTips.lazy.compactMap { tip -> UsageTipPresentation? in
            guard let shortcutLabel = shortcutResolver.displayString(for: tip.shortcutAction) else {
                return nil
            }
            return UsageTipPresentation(tip: tip, shortcutLabel: shortcutLabel, windowID: windowID)
        }.first

        guard let presentation else {
            state = .finished
            return
        }

        state = .presenting(presentation)
        // A one-shot Timer models the generous auto-hide deadline; dismissal never marks the tip seen.
        autoHideTimer = makeTimer(after: autoHideDelay) { [weak self] in
            self?.dismiss()
        }
    }

    private func finishPresentation() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        state = .finished
    }

    private func makeTimer(
        after interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
