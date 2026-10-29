import AppKit
import CmuxNextLaunch
import CmuxNextSettings
import os
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextControl
import CmuxNextOracle
import CmuxNextWakeups
import Observation
#endif

/// Window invariants checked after every membership transition and
/// reported by `debug.windows` (and in `debug.focus`): a window exists only
/// while it owns at least one workspace, every workspace has one window,
/// and controllers match the registry. The only window without a workspace
/// allowed is the unregistered launch window while it shows the daemon's
/// connecting state.
enum WindowInvariants {
    static func problems(_ manager: WindowManager) -> [String] {
        let value = manager.registry.value
        var problems = value.violations()
        for controller in manager.controllers where controller.state.id != manager.launchWindowID {
            let id = controller.state.id
            guard let window = value.window(id) else {
                problems.append("window \(id) is on screen but not registered")
                continue
            }
            if !window.isOpen { problems.append("window \(id) is on screen but closed") }
            if window.workspaceIDs.isEmpty { problems.append("window \(id) has 0 workspaces") }
            if manager.awaitingContent[id] == nil, !window.workspaceIDs.isEmpty, !manager.hasMirroredWorkspace(window) {
                problems.append("window \(id) is presented but none of its workspaces is mirrored")
            }
        }
        for window in value.openWindows where manager.controller(for: window.id) == nil && manager.launchWindows?.isWaiting(window.id) != true {
            problems.append("open window \(window.id) has no controller")
        }
        return problems
    }

    /// `debug.windows`: every registered window and whether the invariants hold.
    static func report(_ manager: WindowManager) -> JSONValue {
        let value = manager.registry.value
        let problems = problems(manager)
        return .object([
            "windows": .array(value.windows.map { window in
                let controller = manager.controller(for: window.id)
                return .object(pageFields(state: manager.states[window.id], controller: controller).merging([
                    "id": .string(window.id),
                    "open": .bool(window.isOpen),
                    "workspaces": .array(window.workspaceIDs.map(JSONValue.string)),
                    "selected": manager.states[window.id]?.workspaceID.map(JSONValue.string) ?? .null,
                    "has_controller": .bool(controller != nil),
                    "launch_build_waits": .bool(manager.launchWindows?.isWaiting(window.id) == true),
                    "visible": .bool(controller?.window?.isVisible ?? false),
                    "awaiting_content": .bool(manager.awaitingContent[window.id] != nil),
                ]) { _, new in new })
            }),
            "recency": .array(value.recency.map(JSONValue.string)),
            // The window server's order of the shown windows: a debug read (the app keeps `recency`).
            "z_order": .array(NSApp.orderedWindows.compactMap { w in manager.controllers.first { $0.window === w }.map { .string($0.state.id) } }),
            "launch_window": manager.launchWindowID.map(JSONValue.string) ?? .null,
            "controllers": .number(Double(manager.controllers.count)),
            "problems": .array(problems.map(JSONValue.string)),
            "violations_seen": .number(Double(manager.invariantViolations)),
            "consistent": .bool(problems.isEmpty),
        ])
    }

    /// The page fields of one window in `debug.windows`.
    /// `page` is the window state's top page, `shown_page` the one drawn.
    static func pageFields(state: WindowState?, controller: WindowController?) -> [String: JSONValue] {
        ["page": state?.page.map { .string($0.rawValue) } ?? .null,
         "shown_page": controller?.shownTopPage.map { .string($0.rawValue) } ?? .null]
    }

    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.windows")
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's `windows` facet (``OracleWindowsFacet``) over this manager's windows.
extension WindowManager {
    /// The app's provider: the windows, the services' key window, and AppKit's main window and screens. Each
    /// read also observes a count of `WindowEvents.stateChanges` posts through `events` (subscribed on the
    /// first read), so a `debug.oracle.wait_for` on a frame or on full screen wakes when AppKit changes them.
    func oracleWindowsFacet(events: AppEvents) -> OracleWindowsFacet {
        let changes = OracleWindowChangeCount(events: events)
        return OracleWindowsFacet { [weak self] () throws(OracleFacetError) -> OracleWindowsFacet.Reading in
            guard let self else { throw OracleFacetError("the window manager is gone") }
            _ = changes.observe()
            return oracleWindows(key: services.keyWindowSource(), main: NSApp.mainWindow, screens: NSScreen.screens)
        }
    }

    /// Every controller's window in the registry's recency (front to back: the app's own order, which each
    /// order and key change updates in ``windowDidOrder(_:inFront:)``); a window the registry does not list
    /// yet (the launch window) comes first. Key and main name the controller that owns AppKit's key or main
    /// window (``owner(of:)``): a Chromium page window, a sheet or a panel over a cmux window counts as that
    /// window, as Chrome reports the focused browser window and not the focused child widget.
    func oracleWindows(key: NSWindow?, main: NSWindow?, screens: [NSScreen]) -> OracleWindowsFacet.Reading {
        let rank = Dictionary(registry.value.recency.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let ordered = controllers.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.state.id] ?? -1
            let right = rank[rhs.element.state.id] ?? -1
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
        let keyOwner = key.flatMap(owner(of:))
        let mainOwner = main.flatMap(owner(of:))
        var reading = OracleWindowsFacet.Reading(screens: screens.map { screen in
            OracleWindowsFacet.Screen(frame: Self.oracleRect(screen.frame), visibleFrame: Self.oracleRect(screen.visibleFrame))
        }, windows: [], key: nil, main: nil)
        for controller in ordered {
            guard let window = controller.window else { continue }
            let id = ControlWindowInfo.publicID(forKey: controller.state.id)
            if controller === keyOwner { reading.key = id }
            if controller === mainOwner { reading.main = id }
            let screenFrame = window.screen?.frame
            reading.windows.append(OracleWindowsFacet.Window(
                id: id, frame: Self.oracleRect(window.frame),
                screen: screenFrame.flatMap { frame in screens.firstIndex { $0.frame == frame } },
                fullscreen: window.styleMask.contains(.fullScreen), miniaturized: window.isMiniaturized, visible: window.isVisible
            ))
        }
        return reading
    }

    private static func oracleRect(_ rect: CGRect) -> OracleWindowsFacet.Rect {
        OracleWindowsFacet.Rect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }
}

/// How many `WindowEvents.stateChanges` posts the app's events delivered, observable: the windows facet's
/// read touches it, so the Observation a wait reads under fires on AppKit's next window change.
@Observable private final class OracleWindowChangeCount {
    private(set) var count = 0
    @ObservationIgnored private let events: AppEvents
    @ObservationIgnored private var subscriptions: [EventSubscription] = []

    init(events: AppEvents) { self.events = events }

    /// The count now, subscribing on the first call (before any wait reads, so no change after a read is missed).
    func observe() -> Int {
        if subscriptions.isEmpty {
            subscriptions = WindowEvents.stateChanges.map { events.subscribe($0, owner: "oracle.windows") { [weak self] in self?.count += 1 } }
        }
        return count
    }
}
#endif
