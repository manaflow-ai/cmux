import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// WINDOW RESIZE 2 (Chrome parity row 5): while a person drags a window edge, each step of the drag is one frame, and
/// the main thread has one refresh (8.33 ms at 120 Hz) for it. The sample of a live corner drag (aws-m4pro-8, bench
/// build 9fb79762c14, 116 steps) showed work in each step that does not depend on the window's size: the sidebar's
/// layout called `ProfileBarView.refresh()` each time, which made the space switcher's tooltips and accessibility
/// elements again and drew its marks again, although a window resize moves the bar and changes nothing in it.
///
/// The Chrome model (CLAUDE.md "Copy Chrome's performance model"): a resize frame lays out the boxes whose size
/// changes and paints what changed; a box that only moves is not painted again.
///
/// The rules, counted on a window as the app builds it (sidebar, main pane card, one pane), over the steps of a
/// corner drag 1280x800 -> 1040x640, at each session size:
/// 1. The space switcher is not drawn again, and keeps its accessibility elements and its tooltips (the same objects).
/// 2. No view is laid out twice in one step.
/// The suite prints one `WORK` line per arm with the layout calls per view class (the numbers of the PR's table).
@MainActor @Suite(.serialized, .closesItsWindows) struct WindowResizeWorkPerStepTests {
    /// The session arms (FABLE-COMMON "Session size rule"): the workspaces the sidebar lists. `light` always runs; the
    /// environment of the test run names the others as for the large-session suites (`CMUX_TEST_SESSION_SIZES=real`
    /// or `large,real`), `large` when it names none. A size is one argument of each test.
    nonisolated enum Session: String, Sendable, CustomTestStringConvertible {
        case light, large, real

        var workspaces: Int {
            switch self {
            case .light: 3
            case .large: 60
            case .real: 826
            }
        }

        var testDescription: String { "\(rawValue) (\(workspaces) workspaces)" }

        static let arms: [Session] = {
            let named = (ProcessInfo.processInfo.environment["CMUX_TEST_SESSION_SIZES"] ?? "")
                .split(separator: ",").compactMap { Session(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            var arms: [Session] = [.light]
            for size in named.isEmpty ? [.large] : named where !arms.contains(size) { arms.append(size) }
            return arms
        }()
    }

    static let steps = 20
    static let start = CGSize(width: 1280, height: 800), end = CGSize(width: 1040, height: 640)

    /// A window as the app builds it: the sidebar with `session`'s workspaces and 3 spaces, the main pane card and one
    /// workspace with one pane.
    @MainActor final class Rig {
        let window: NSWindow
        let root: WindowRootView
        let layout: LayoutRootView
        let provider = LayoutWorkProbe.Panes()
        var sidebar: SidebarView { root.sidebar.sidebarView }
        var bar: ProfileBarView { sidebar.profileBar }
        /// Draws of the space switcher's marks since ``countDraws()``.
        private(set) var markDraws = 0

        init(_ session: Session) {
            _ = NSApplication.shared
            LayoutPassGuard.shared.install()
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let ids = (0..<session.workspaces).map { WorkspaceID("resize-\($0)") }
            let nodes = ids.enumerated().map { index, id in
                SidebarNode.workspace(SidebarWorkspace(id: id, title: "project-\(index)", directory: "~/p\(index)"))
            }
            let sidebarModel = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)],
                                            activeWorkspaceID: ids[ids.count - 1])
            let spaces = (0..<3).map { ProfileKey("space\($0)") }
            sidebarModel.profiles = spaces.enumerated().map { SidebarProfile(id: $1, name: "Space \($0)") }
            sidebarModel.activeProfileID = spaces[0]
            let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))],
                                    activeScreenID: "s", focusedPane: "p1")
            layout = LayoutRootView(model: model, contentProvider: provider)
            root = WindowRootView(sidebar: SidebarContainerView(model: sidebarModel))
            window = NSWindow(contentRect: NSRect(origin: .zero, size: WindowResizeWorkPerStepTests.start),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentView = root
            root.show(layout)
            sidebar.renderNow()
            for _ in 0..<2 {
                root.needsLayout = true
                root.layoutSubtreeIfNeeded()
            }
            show()
        }

        func close() { window.closeAfterTest() }

        /// The frame's layout and display, and the draw of each layer that asked for one.
        func show() {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            var layers: [CALayer] = root.layer.map { [$0] } ?? []
            while let layer = layers.popLast() {
                layer.displayIfNeeded()
                layers.append(contentsOf: layer.sublayers ?? [])
            }
        }

        /// One step of a live resize: the window takes `size` (AppKit lays the view tree out inside `setFrame`, as in
        /// a drag of the edge), then the frame's own layout and display.
        func step(to size: CGSize) {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            show()
        }

        /// Counts the draws of the space switcher's marks from now.
        func countDraws() {
            markDraws = 0
            let draw = bar.marks.onDraw
            bar.marks.onDraw = { [weak self] rect in
                self?.markDraws += 1
                draw?(rect)
            }
        }

        /// The window's views per class name (as `LayoutPassGuard` names a class), with each one's size.
        func views() -> [ObjectIdentifier: (viewClass: String, size: CGSize)] {
            guard let top = window.contentView?.superview ?? window.contentView else { return [:] }
            return KeyResizeLayoutsPerFrameTests.sizes(under: top)
        }
    }

    /// The window's size at `step` of ``steps`` (1 is the first step, ``steps`` the last).
    static func size(at step: Int) -> CGSize {
        let part = CGFloat(step) / CGFloat(steps)
        return CGSize(width: (start.width + (end.width - start.width) * part).rounded(),
                      height: (start.height + (end.height - start.height) * part).rounded())
    }

    /// A window resize moves the space switcher and changes nothing in it: its marks are not drawn again, and its
    /// accessibility elements and tooltips stay the ones VoiceOver and the pointer already have.
    @Test(arguments: Session.arms)
    func aResizeStepDoesNotRebuildTheSpaceSwitcher(session: Session) throws {
        let rig = Rig(session)
        defer { rig.close() }
        let bar = rig.bar
        try #require(bar.window === rig.window && !bar.isHiddenOrHasHiddenAncestor && bar.bounds.width > 0,
                     "fixture: the window shows no space switcher")
        let size = bar.frame.size
        let elements = try #require(bar.accessibilityChildren() as? [NSAccessibilityElement])
        try #require(elements.count == 4, "fixture: \(elements.count) accessibility elements for 3 spaces and the +")
        let tips = TooltipTracker.all(of: bar)
        try #require(tips.count == 4, "fixture: \(tips.count) tooltips for 3 spaces and the +")
        rig.countDraws()
        for step in 1...Self.steps { rig.step(to: Self.size(at: step)) }
        try #require(rig.window.frame.size == Self.end, "fixture: the window did not take the last size")
        try #require(bar.frame.size == size, "fixture: the resize changed the switcher's size, \(size) to \(bar.frame.size)")
        let elementsNow = bar.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        let tipsNow = TooltipTracker.all(of: bar)
        #expect(rig.markDraws == 0, "\(Self.steps) resize steps drew the space switcher's marks \(rig.markDraws) times")
        #expect(elementsNow.count == elements.count && zip(elementsNow, elements).allSatisfy { $0 === $1 },
                "the resize made the space switcher's accessibility elements again")
        #expect(tipsNow.count == tips.count && zip(tipsNow, tips).allSatisfy { $0 === $1 },
                "the resize made the space switcher's tooltips again")
    }

    /// One step lays a view out one time at most, at each session size. Prints the `WORK` line of the arm.
    @Test(arguments: Session.arms)
    func aResizeStepLaysAViewOutOnce(session: Session) throws {
        let rig = Rig(session)
        defer { rig.close() }
        typealias Counts = KeyResizeLayoutsPerFrameTests
        var twice: [String] = []
        var total: [String: Int] = [:], resizedTotal: [String: Int] = [:]
        let began = Counts.calls()
        for step in 1...Self.steps {
            let before = rig.views()
            let start = Counts.calls()
            rig.step(to: Self.size(at: step))
            let laid = Counts.since(start)
            let after = rig.views()
            var count: [String: Int] = [:], resized: [String: Int] = [:]
            for (id, entry) in after {
                count[entry.viewClass, default: 0] += 1
                if before[id]?.size != entry.size { resized[entry.viewClass, default: 0] += 1 }
            }
            for (viewClass, calls) in laid {
                total[viewClass, default: 0] += calls
                if calls > count[viewClass, default: 0] {
                    twice.append("step \(step): \(viewClass) laid out \(calls)x, the window has \(count[viewClass, default: 0])")
                }
            }
            for (viewClass, views) in resized { resizedTotal[viewClass, default: 0] += views }
        }
        let calls = Counts.since(began).values.reduce(0, +)
        let classes = total.sorted { $0.value > $1.value }.prefix(24)
            .map { "\($0.key)=\($0.value)/\(resizedTotal[$0.key, default: 0])" }.joined(separator: " ")
        print("WORK case=window-resize session=\(session.rawValue) workspaces=\(session.workspaces) steps=\(Self.steps) "
            + "views=\(rig.views().count) layout_calls=\(calls) per_step=\(String(format: "%.1f", Double(calls) / Double(Self.steps))) "
            + "laid/resized: \(classes)")
        #expect(twice.isEmpty, "\(twice.count) views laid out more than one time in a step: \(twice.prefix(12))")
    }
}
