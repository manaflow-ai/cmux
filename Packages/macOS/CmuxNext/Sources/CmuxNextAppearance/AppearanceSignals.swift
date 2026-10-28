#if canImport(AppKit)
import AppKit
#endif
public import CmuxNextDesignTokens
public import CmuxNextWakeups
import Foundation
public import Observation

/// The app-wide appearance inputs that used to be broadcast as notifications: Reduce Motion (the
/// system's, the tests' pin and calm mode), the motion switches (`ui.animationSpeed`,
/// `ui.animations.enabled`, the category switches), hover cards, the inactive window dim and the
/// system's Accessibility > Display options (plans/cmux-next/chrome-parity/p06-scheduler.md, 043).
///
/// It is `@Observable`: a SwiftUI body or a ``VisibleObservation`` that reads ``reduceMotion``
/// (through `Motion`), ``display``, ``showsHoverCards`` or ``inactiveWindowDim`` re-reads when they
/// change, and only while it is on screen. An AppKit owner with no Observation scope subscribes to
/// the ``Signal``s it follows (``subscribe(_:node:delivery:owner:_:)``): a subscriber whose node does
/// not render (hidden, and no capture vote holds it) gets no call, and one ``EventCall/missed``
/// call when the node renders again.
///
/// The system's display options are observed once for the whole app: the composition root hands
/// its workspace ``AppEvents`` to ``observeDisplayOptions(through:)``. Chromium does the same:
/// `NativeThemeMac` observes `NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification` once
/// (`ui/native_theme/native_theme_mac.mm`), caches the values (`gfx::Animation`'s
/// `prefers_reduced_motion_`, `ui/gfx/animation/animation_mac.mm`) and notifies its
/// `NativeThemeObserver`s, not one observer per view.
///
/// Each ``DesignSettings`` owns one (``DesignSettings/signals``); `Motion` reads the app's,
/// `DesignSettings.shared.signals`.
///
/// ```swift
/// motionWatch = DesignSettings.shared.signals.subscribe([.motion], owner: "BackdropVideoView") { [weak self] in
///     self?.update()
/// }
/// ```
@MainActor @Observable
public final class AppearanceSignals {
    /// What changed, for ``subscribe(_:node:delivery:owner:_:)``.
    public nonisolated enum Signal: Sendable, Hashable, CaseIterable {
        /// Reduce Motion as `Motion` reads it: the system setting, the tests' pin or calm mode.
        case reduceMotion
        /// What every motion gate reads: `ui.animationSpeed`, `ui.animations.enabled`, a category
        /// switch, calm mode, Reduce Motion or Energy Saver (``DesignSettings/energySaver``).
        case motion
        /// Whether hover cards open (`sidebar.hoverCards.enabled` or calm mode).
        case hoverCards
        /// `appearance.inactiveWindowDim`.
        case inactiveDim
        /// One of the system's Accessibility > Display options (``DisplayOptions``).
        case displayOptions
        /// A value every theme payload reads changed: calm mode (hover fills) or the terminal's
        /// face (``DesignSettings/effectiveTerminalFontFamily``). The app's theme store repaints
        /// every window and page (`ThemeStore.repaintAll`); raised after the signals of the same
        /// change, so a repaint reads values their subscribers already updated.
        case themeRepaint
    }

    /// The system's Accessibility > Display options.
    public nonisolated struct DisplayOptions: Equatable, Sendable {
        public var reduceMotion: Bool
        public var reduceTransparency: Bool
        public var increaseContrast: Bool
        public var differentiateWithoutColor: Bool

        public init(reduceMotion: Bool = false, reduceTransparency: Bool = false, increaseContrast: Bool = false,
                    differentiateWithoutColor: Bool = false) {
            self.reduceMotion = reduceMotion
            self.reduceTransparency = reduceTransparency
            self.increaseContrast = increaseContrast
            self.differentiateWithoutColor = differentiateWithoutColor
        }

        /// This Mac's options now; the defaults where the system has none to read (Linux).
        @MainActor public static var system: DisplayOptions {
            #if canImport(AppKit)
            let workspace = NSWorkspace.shared
            return DisplayOptions(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                                  reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                                  increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                                  differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor)
            #else
            return DisplayOptions()
            #endif
        }
    }

    /// A subscription to ``AppearanceSignals``. Releasing it (or ``cancel()``) ends it.
    @MainActor public final class Subscription {
        /// The subscriber's name for diagnostics.
        public let owner: String
        fileprivate let signals: Set<Signal>
        private weak var node: VisibilityNode?
        private let delivery: EventDelivery
        private let handler: @MainActor (EventCall) -> Void
        /// A signal came while the node did not render; its missed call waits until it does.
        private var missed = false
        public private(set) var isCancelled = false

        fileprivate init(signals: Set<Signal>, node: VisibilityNode?, delivery: EventDelivery, owner: String,
                         handler: @escaping @MainActor (EventCall) -> Void) {
            self.signals = signals
            self.node = node
            self.delivery = delivery
            self.owner = owner
            self.handler = handler
        }

        /// Ends the subscription now: no later call, a pending missed call included. Idempotent.
        public func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            if missed { node?.cancelDeferred(key: ObjectIdentifier(self)) }
            missed = false
        }

        fileprivate func post() {
            guard !isCancelled else { return }
            guard delivery == .whenVisible else { return handler(.posted) }
            // A released node's view is gone: nothing to update.
            guard let node else { return }
            if node.wantsFrames { return handler(.posted) }
            guard !missed else { return }
            missed = true
            node.deferUntilVisible(key: ObjectIdentifier(self)) { [weak self] in self?.deliverMissed() }
        }

        private func deliverMissed() {
            guard missed, !isCancelled else { return }
            missed = false
            handler(.missed)
        }
    }

    /// The system's Accessibility > Display options, as last read.
    public private(set) var display: DisplayOptions
    /// Pins Reduce Motion (tests, `debug.motion reduce`); nil follows the system and calm mode.
    public var reduceMotionOverride: Bool? {
        didSet {
            guard reduceMotionOverride != oldValue else { return }
            // A pin is news to the hosts that mirror it (HomeReduceMotion) even when the effective
            // value stays.
            settle([.reduceMotion, .motion])
        }
    }

    /// The settings that own these signals (they hold the signals).
    @ObservationIgnored private weak var design: DesignSettings?
    private let readDisplay: @MainActor () -> DisplayOptions
    /// The fan-out the display notice comes through (a subscription holds it weakly).
    @ObservationIgnored private var displayEvents: AppEvents?
    @ObservationIgnored private var displayWatch: EventSubscription?
    @ObservationIgnored private var subscribers: [WeakSubscription] = []
    /// The list length at which a new subscription first drops released ones, doubled after each
    /// pass, so dropping costs O(1) amortized per subscription.
    @ObservationIgnored private var pruneAt = 16
    /// ``reduceMotion`` as the subscribers last heard it.
    @ObservationIgnored private var announcedReduceMotion: Bool

    /// - Parameters:
    ///   - design: The settings whose calm mode, motion switches, hover cards and dim it reports.
    ///   - display: Reads the system's display options (``DisplayOptions/system``; tests pass their own).
    init(design: DesignSettings, display: @escaping @MainActor () -> DisplayOptions) {
        self.design = design
        readDisplay = display
        let options = display()
        self.display = options
        announcedReduceMotion = options.reduceMotion || design.calmMode.reducesMotion
    }

    // MARK: Values

    /// System Reduce Motion or calm mode (`ui.calm`), or the pin.
    public var reduceMotion: Bool { reduceMotion(calm: design?.calmMode ?? .off) }

    /// ``reduceMotion`` with `other`'s calm mode: the pin and the system setting are the app's.
    public func reduceMotion(of other: DesignSettings) -> Bool { reduceMotion(calm: other.calmMode) }

    /// Hover cards open on hover (``DesignSettings/showsHoverCards``).
    public var showsHoverCards: Bool { design?.showsHoverCards ?? true }

    /// `appearance.inactiveWindowDim` (``DesignSettings/inactiveWindowDim``).
    public var inactiveWindowDim: Double { design?.inactiveWindowDim ?? 0 }

    private func reduceMotion(calm: CalmMode) -> Bool {
        reduceMotionOverride ?? (display.reduceMotion || calm.reducesMotion)
    }

    // MARK: Sources

    /// Observes the system's display options through `events` (a fan-out on
    /// `NSWorkspace.shared.notificationCenter`, kept here): the app's one observer of
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`. A later call replaces it.
    /// Where the system has no such options (Linux) it reads the defaults once.
    public func observeDisplayOptions(through events: AppEvents) {
        displayEvents = events
        #if canImport(AppKit)
        displayWatch = events.subscribe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                        owner: "AppearanceSignals") { [weak self] in
            self?.refreshDisplayOptions()
        }
        #endif
        refreshDisplayOptions()
    }

    /// Reads the display options again and tells the subscribers when they changed.
    public func refreshDisplayOptions() {
        let options = readDisplay()
        guard options != display else { return }
        display = options
        settle([.displayOptions])
    }

    /// A ``DesignSettings`` property behind `changed` was set to a new value.
    func designChanged(_ changed: Set<Signal>) {
        settle(changed)
    }

    // MARK: Subscribers

    /// Calls `handler` when one of `signals` changes, by `node`'s visibility.
    ///
    /// - Parameters:
    ///   - signals: What the subscriber follows.
    ///   - node: The subscriber's node (held weakly); nil calls on every change.
    ///   - delivery: ``EventDelivery/whenVisible`` for view work (a hidden node gets one
    ///     ``EventCall/missed`` call on show), ``EventDelivery/always`` for work a person waits for
    ///     while the view is hidden.
    ///   - owner: The subscriber's name for diagnostics.
    ///   - handler: Main-actor work; it reads the current values.
    /// - Returns: The subscription; keep it, releasing it ends the subscription.
    public func subscribe(_ signals: Set<Signal>, node: VisibilityNode?, delivery: EventDelivery, owner: String,
                          _ handler: @escaping @MainActor (EventCall) -> Void) -> Subscription {
        let subscription = Subscription(signals: signals, node: node, delivery: delivery, owner: owner, handler: handler)
        if subscribers.count >= pruneAt {
            subscribers.removeAll { $0.subscription?.isCancelled ?? true }
            pruneAt = max(16, 2 * subscribers.count)
        }
        subscribers.append(WeakSubscription(subscription: subscription))
        return subscription
    }

    /// Calls `handler` on every change of one of `signals`: for an owner with no node (an app-wide
    /// cache, a window's tracker).
    public func subscribe(_ signals: Set<Signal>, owner: String, _ handler: @escaping @MainActor () -> Void) -> Subscription {
        subscribe(signals, node: nil, delivery: .always, owner: owner) { _ in handler() }
    }

    /// A view's subscription: on `node` with ``EventDelivery/whenVisible`` (a hidden view gets one
    /// ``EventCall/missed`` call when it shows), or on every change while the view has no node yet
    /// (it is not in a pane's visibility tree).
    public func subscribe(_ signals: Set<Signal>, viewNode node: VisibilityNode?, owner: String,
                          _ handler: @escaping @MainActor () -> Void) -> Subscription {
        subscribe(signals, node: node, delivery: node == nil ? .always : .whenVisible, owner: owner) { _ in handler() }
    }

    /// How many subscriptions to `signal` are live.
    package func subscriberCount(_ signal: Signal) -> Int {
        subscribers.count(where: { entry in entry.subscription.map { !$0.isCancelled && $0.signals.contains(signal) } ?? false })
    }

    /// Whether it observes the system's display options.
    package var observesDisplayOptions: Bool { displayWatch != nil }

    /// Adds a Reduce Motion flip to `changed` and calls the subscribers of what changed, in the
    /// order they subscribed.
    private func settle(_ changed: Set<Signal>) {
        var changed = changed
        let reduced = reduceMotion
        if reduced != announcedReduceMotion {
            announcedReduceMotion = reduced
            changed.formUnion([.reduceMotion, .motion])
        }
        guard !changed.isEmpty else { return }
        // A handler may subscribe or cancel: walk the list as it was.
        for entry in subscribers {
            guard let subscription = entry.subscription, !subscription.signals.isDisjoint(with: changed) else { continue }
            subscription.post()
        }
    }

    private struct WeakSubscription {
        weak var subscription: Subscription?
    }
}
