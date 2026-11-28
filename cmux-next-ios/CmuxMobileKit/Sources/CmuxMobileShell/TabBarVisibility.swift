#if os(iOS)
import CmuxMobileDesign
import OSLog
import SwiftUI
import UIKit

private let tabBarLog = Logger(subsystem: "dev.cmux.mobile", category: "tabbar")

/// One tab's root tab bar, shown or hidden by ``ShellModel/showsTabBar(on:)``:
/// the only thing that decides it. Applied by `ShellTabs` to each tab's
/// content, outside its navigation stack.
///
/// SwiftUI's `.toolbar(_:for: .tabBar)` alone is not enough. It drops the
/// hide when a tab is selected and pushed on in one update (a link, a
/// notification tap, the Feed's terminal events, the launch restore): the
/// pushed screen then shows over the bar. So the same value also goes to
/// the tab bar controller itself, every time SwiftUI could have changed it.
struct TabBarVisibility: ViewModifier {
    let shell: ShellModel
    let tab: RootTab

    func body(content: Content) -> some View {
        let shows = shell.showsTabBar(on: tab)
        content
            .toolbar(shows ? .visible : .hidden, for: .tabBar)
            .background(TabBarVisibilityEnforcer(hidden: !shows, rootRequested: shell.depth(of: tab) == 0, moving: { [shell, tab] moving in
                guard shell.stackMoving.contains(tab) != moving else { return }
                if moving { shell.stackMoving.insert(tab) } else { shell.stackMoving.remove(tab) }
            }))
    }
}

/// Sets `UITabBarController.isTabBarHidden` to the shell's value for the tab
/// it sits in, when that tab is on screen: on each update, when the tab
/// appears, and on each layout (SwiftUI's own tab bar changes lay the tab out
/// again).
private struct TabBarVisibilityEnforcer: UIViewControllerRepresentable {
    let hidden: Bool
    let rootRequested: Bool
    /// Told when the tab's navigation stack starts and stops a transition.
    let moving: (Bool) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hidden = hidden
        controller.rootRequested = rootRequested
        controller.moving = moving
        controller.apply(animated: !context.transaction.disablesAnimations)
    }

    final class Controller: UIViewController {
        var hidden = false
        var rootRequested = true
        var moving: ((Bool) -> Void)?
        private var watched: [ObjectIdentifier] = []

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply(animated: false)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(animated: false)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            watchStack()
            apply(animated: false)
        }

        /// The tab's own navigation stack (the one in the tab this sits in).
        private var stack: UINavigationController? {
            var tabRoot: UIViewController? = self
            while let controller = tabRoot, !(controller.parent is UITabBarController) { tabRoot = controller.parent }
            guard let tabRoot else { return nil }
            var queue: [UIViewController] = [tabRoot]
            while !queue.isEmpty {
                let controller = queue.removeFirst()
                if let navigation = controller as? UINavigationController { return navigation }
                queue += controller.children
            }
            return nil
        }

        /// A swipe back starts its transition before SwiftUI empties the path: follow it from
        /// its first frame, so the root chrome waits for the page to leave.
        private func watchStack() {
            guard let navigation = stack else { return }
            var gestures: [UIGestureRecognizer] = []
            if let pop = navigation.interactivePopGestureRecognizer { gestures.append(pop) }
            if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer { gestures.append(content) }
            for gesture in gestures where !watched.contains(ObjectIdentifier(gesture)) {
                gesture.addTarget(self, action: #selector(popGestureChanged(_:)))
                watched.append(ObjectIdentifier(gesture))
            }
        }

        @objc private func popGestureChanged(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed { follow() }
        }

        /// The hold's sequencing (`RootHoldDriver`), read from this tab's stack. The driver keeps
        /// the shell's `moving` itself, and a transition's completion keeps the driver alive, so
        /// losing this controller mid-pop still ends the hold (its stack then reads as gone).
        private lazy var hold: RootHoldDriver = {
            let driver = RootHoldDriver(
                read: { [weak self] in
                    guard let self else { return RootHoldReading(transition: nil, rootRequested: true, depth: nil) }
                    let navigation = self.stack
                    return RootHoldReading(transition: navigation?.transitionCoordinator.map { $0 as AnyObject },
                                           rootRequested: self.rootRequested, depth: navigation?.viewControllers.count)
                },
                register: { [weak self] done in
                    guard let coordinator = self?.stack?.transitionCoordinator else { return false }
                    return coordinator.animate(alongsideTransition: nil) { _ in MainActor.assumeIsolated { done() } }
                },
                after: { delay, work in
                    if delay > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
                    } else {
                        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
                    }
                },
                enabled: { !SwipeBackWholePage.legacy }
            )
            driver.onBound = { depth in
                tabBarLog.error("root hold released at its bound: UIKit did not pop (depth \(depth ?? -1, privacy: .public))")
            }
            return driver
        }()

        /// Reports the stack moving until its transition ends (finished or cancelled).
        /// `later`: called from a SwiftUI update, which must not change the shell's state.
        private func follow(later: Bool = false) {
            hold.moving = moving
            hold.follow(deferReport: later)
        }

        /// Decide the tab's root hold from the stack as it is now. Runs whether or not the tab
        /// is selected: a hidden tab's emptied path must not stay held until it is shown again
        /// (#56696 F1).
        private func settle() {
            hold.moving = moving
            hold.settle()
        }

        /// Only the selected tab decides: a hidden tab's stack says nothing
        /// about the bar on screen.
        ///
        /// `setTabBarHidden` only moves the bar out of sight: its buttons stay
        /// in the accessibility tree (VoiceOver reached Home and Workspaces
        /// over a workspace) and at their frames. So a hidden bar is also
        /// hidden from accessibility and takes no touches, and a shown one
        /// gets both back; the three are set together every time.
        func apply(animated: Bool) {
            if !SwipeBackWholePage.legacy { settle() }
            guard let tabs = tabBarController, let selected = tabs.selectedViewController,
                  isDescendant(of: selected) else { return }
            // Keep root chrome out until the page has left, including programmatic Back.
            if !SwipeBackWholePage.legacy, rootRequested, stack?.transitionCoordinator != nil { return }
            let bar = tabs.tabBar
            guard tabs.isTabBarHidden != hidden || bar.accessibilityElementsHidden != hidden
                || bar.isUserInteractionEnabled == hidden else { return }
            tabBarLog.info("tab bar \(self.hidden ? "hidden" : "shown", privacy: .public) by the shell")
            // A page pushed over the tab: the bar goes at once instead of fading out over the
            // page coming in (it comes back after the page leaves, above).
            let pushing = hidden && !SwipeBackWholePage.legacy && stack?.transitionCoordinator != nil
            if tabs.isTabBarHidden != hidden { tabs.setTabBarHidden(hidden, animated: animated && !pushing && view.window != nil) }
            bar.accessibilityElementsHidden = hidden
            bar.isUserInteractionEnabled = !hidden
        }

        private func isDescendant(of ancestor: UIViewController) -> Bool {
            var current: UIViewController? = self
            while let controller = current {
                if controller === ancestor { return true }
                current = controller.parent
            }
            return false
        }
    }
}
#endif

import Foundation

/// What a tab's root hold does next (`TabBarVisibilityEnforcer`): the hold keeps the tab bar and
/// New Task out while a page leaves the tab's stack. A pure rule, so each way UIKit can (not) pop
/// is a unit test (`RootHoldTests`).
enum RootHoldStep: Equatable {
    /// A transition runs that reports its end: hold until it completes, then decide again.
    case follow
    /// The path is empty but UIKit has not popped, or its transition will not report its end:
    /// hold, look again.
    case wait
    /// The stack is settled (or there is nothing to wait on): show the root chrome.
    case release
}

enum RootHold {
    /// The longest the hold waits for a pop UIKit never starts, or on a transition that will not
    /// report its end. Failing open (root chrome shown) beats a tab bar that never returns
    /// (#56696 F1).
    static let bound: TimeInterval = 1.0
    /// How often a waiting hold looks at the stack again.
    static let recheck: TimeInterval = 0.05

    /// `transitioning`: the stack has a transition coordinator. `rootRequested`: the tab's path
    /// is empty. `depth`: the stack's view controllers (nil: no stack found). `waited`: how long
    /// this hold has waited on a pop that has not started. `declined`: how long ago UIKit declined
    /// to report the end of the running transition (nil: it did not).
    ///
    /// A transition that reports its end (every animated one: a slow push or pop, an interactive
    /// swipe) is followed for as long as it runs, never released at the bound. Only one UIKit
    /// declined to report (a nonanimated or already ending change) waits on the bound.
    static func step(transitioning: Bool, rootRequested: Bool, depth: Int?, waited: TimeInterval,
                     declined: TimeInterval? = nil) -> RootHoldStep {
        if transitioning {
            guard let declined else { return .follow }
            return declined < bound ? .wait : .release
        }
        // A page is (again) pushed: a hold means nothing under it.
        guard rootRequested else { return .release }
        // No stack to wait on: nothing would ever release the hold.
        guard let depth, depth > 1 else { return .release }
        return waited < bound ? .wait : .release
    }

    static func step(_ reading: RootHoldReading, waited: TimeInterval, declined: TimeInterval?) -> RootHoldStep {
        step(transitioning: reading.transition != nil, rootRequested: reading.rootRequested, depth: reading.depth,
             waited: waited, declined: declined)
    }
}

/// The tab's stack as the hold reads it.
struct RootHoldReading: Equatable {
    /// The running transition's coordinator (nil: none), compared by identity. The object
    /// itself, not its `ObjectIdentifier`: a dead coordinator's address can be reused by the next
    /// one, and an identifier alone would read that new transition as the old.
    var transition: AnyObject?
    /// The tab's path is empty.
    var rootRequested: Bool
    /// The stack's view controllers (nil: no stack found).
    var depth: Int?

    static func == (lhs: RootHoldReading, rhs: RootHoldReading) -> Bool {
        lhs.transition === rhs.transition && lhs.rootRequested == rhs.rootRequested && lhs.depth == rhs.depth
    }
}

/// A transition UIKit declined to report the end of. Weak: once that coordinator is gone, the
/// decline (and its clock) means nothing, and nothing can mistake a later coordinator for it.
@MainActor
private final class DeclinedTransition {
    weak var transition: AnyObject?
    let since: Date
    var logged = false

    init(_ transition: AnyObject, since: Date) {
        self.transition = transition
        self.since = since
    }

    /// Still the same live coordinator as `other`.
    func matches(_ other: AnyObject?) -> Bool {
        guard let transition, let other else { return false }
        return transition === other
    }
}

/// Runs `RootHold.step` against the stack over time: when it reads, follows, rechecks and
/// releases. No UIKit here (the enforcer passes closures), so tests drive its sequencing with
/// a fake clock and scheduler (`RootHoldDriverTests`).
@MainActor
final class RootHoldDriver {
    /// Tells the shell the tab's stack is moving (true) or settled (false).
    var moving: ((Bool) -> Void)?
    /// Called when a hold is released at `RootHold.bound` (the depth it gave up on).
    var onBound: ((Int?) -> Void)?

    private let read: @MainActor () -> RootHoldReading
    /// Asks the running transition to call back when it ends; false: UIKit declined.
    private let register: @MainActor (@escaping @MainActor () -> Void) -> Bool
    /// Runs work on the main queue after a delay (0: the next turn).
    private let after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let enabled: @MainActor () -> Bool
    private let now: @MainActor () -> Date

    private(set) var following = false
    /// When the hold first waited on a pop UIKit had not started (nil: not waiting).
    private var waitingSince: Date?
    /// The transition UIKit declined to report the end of, and since when (weakly held).
    private var declined: DeclinedTransition?
    /// A declined transition is remembered and still alive (tests).
    var holdsDeclinedTransition: Bool { declined?.transition != nil }
    private var recheckScheduled = false
    private var releaseScheduled = false

    init(read: @escaping @MainActor () -> RootHoldReading,
         register: @escaping @MainActor (@escaping @MainActor () -> Void) -> Bool,
         after: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void,
         enabled: @escaping @MainActor () -> Bool = { true },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.read = read
        self.register = register
        self.after = after
        self.enabled = enabled
        self.now = now
    }

    /// Hold while the running transition runs. `deferReport`: called from a SwiftUI update,
    /// which must not change the shell's state.
    func follow(deferReport: Bool = false) {
        guard enabled(), !following, let transition = read().transition else { return }
        // UIKit already declined this transition: wait on it (bounded), do not ask again.
        if declined?.matches(transition) == true { scheduleRecheck(); return }
        // A remembered decline whose coordinator is gone, or another one: forget it.
        declined = nil
        following = true
        if deferReport {
            after(0) { [weak self] in
                // Still holding: following, or waiting on a transition UIKit declined to report.
                guard let self, self.following || self.declined?.matches(transition) == true else { return }
                self.moving?(true)
            }
        } else {
            moving?(true)
        }
        // The completion keeps the driver alive until the transition settles. It is not a
        // release by itself: this transition may be a push that a Back emptied the path during,
        // whose pop UIKit has not started yet (#56696 F2). The next turn reads the stack as it
        // settled and releases only at its root.
        let accepted = register { [self] in
            following = false
            after(0) { [self] in settle() }
        }
        if !accepted {
            // A nonanimated or ending change: UIKit will not report its end. Hold on, and look
            // again on the recheck timer (not at once: that would ask again every turn), bounded
            // from the first decline by `RootHold.bound`.
            following = false
            declined = DeclinedTransition(transition, since: now())
            scheduleRecheck()
        }
    }

    /// Decide the hold from the stack as it is now: follow, wait (bounded), or release.
    func settle() {
        guard enabled(), !following else { return }
        let reading = read()
        // Keep the decline's clock only while the same coordinator is alive and still running.
        if let declined, !declined.matches(reading.transition) { self.declined = nil }
        let at = now()
        let waited = waitingSince.map { at.timeIntervalSince($0) } ?? 0
        switch RootHold.step(reading, waited: waited, declined: declined.map { at.timeIntervalSince($0.since) }) {
        case .follow:
            waitingSince = nil
            follow(deferReport: true)
        case .wait:
            if reading.transition == nil, waitingSince == nil { waitingSince = at }
            scheduleRecheck()
        case .release:
            release(decided: reading)
        }
    }

    /// Release on the next turn (a SwiftUI update must not change the shell's state), and only
    /// if the stack still reads as it did when release was decided: a push, a pop or a new
    /// transition in between decides again instead.
    private func release(decided: RootHoldReading) {
        guard !releaseScheduled else { return }
        releaseScheduled = true
        after(0) { [self] in
            releaseScheduled = false
            guard enabled(), !following else { return }
            let current = read()
            guard current == decided else { settle(); return }
            let at = now()
            let waited = waitingSince.map { at.timeIntervalSince($0) } ?? 0
            let declinedFor = declined.map { at.timeIntervalSince($0.since) }
            if waited >= RootHold.bound || ((declinedFor ?? 0) >= RootHold.bound && declined?.logged == false) {
                onBound?(current.depth)
            }
            declined?.logged = true
            waitingSince = nil
            // A declined transition still running stays declined: asking it again would hold
            // the chrome for another bound, and again, instead of once.
            if current.transition == nil { declined = nil }
            moving?(false)
        }
    }

    private func scheduleRecheck() {
        guard !recheckScheduled else { return }
        // UIKit starts the pop within a frame or two of SwiftUI emptying the path, and no layout
        // or update is promised to reach the enforcer when it does (a nonanimated pop): look
        // again on a short timer until the bound.
        recheckScheduled = true
        after(RootHold.recheck) { [self] in
            recheckScheduled = false
            settle()
        }
    }
}
