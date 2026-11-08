import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSidebar
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// RESIZE P0 7 cause M2 (px-keys-held-2-s1r, cmux21 120 Hz 1x, build fe0d956f, frames.json marks): in each spring frame
/// of a keyboard resize the window's frame view (`NSThemeFrame`) lays out 1-2 times. The mark stacks:
/// `TerminalSurfaceView.setFrameSize` / `PaneHostView.setFrameSize` -> `-[NSView setFrameSize:]` ->
/// `NSViewUpdateConstraintsForFrameChange` -> `_updateSimpleAutoresizingConstraintsInPlace:` -> the frame view's
/// `needsLayout`, so the CA commit's `-[NSWindow layoutIfNeeded]` runs a window pass in every spring frame. Chrome's
/// views place their children by frame and lay out only the boxes whose size changed.
///
/// The rule: in the app's own window (`ShellWindow` with its `WindowRootView`, the layout shown in its main pane as
/// `WindowRootView.show` puts it there) with a terminal in each pane, a spring frame's window pass
/// (`NSWindow.layoutIfNeeded`, as the CA commit runs it) lays out no view whose size did not change in that frame: in
/// particular not the window's frame view.
///
/// RESIZE P0 10 M2 (fleet jobs 2b94bda9fba98acbaf2c3ca4, 227f67a29d622c426da19164, 88ac032e80067f9295280828): a titled
/// `ShellWindow` with no constraint in its content tree runs no frame-view pass (`titledPlain`). One explicit
/// constraint anywhere in the content tree, even inside a sibling's subtree as the sidebar's are, makes AppKit give
/// every view of the tree autoresizing-mask constraints (`LayoutRootView`, `PaneHostView`, `TerminalSurfaceView`), and
/// the frame view then lays out in 16 of 27 spring frames. The layout not translating its mask, or a container that
/// runs no constraint update for its subtree, does not stop it. `WindowRootView` (41 constraints) and the sidebar
/// (`SidebarView` 68, its cards) are Auto Layout, so the app's window is red until its content tree places by frame.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct SpringFrameNoWindowPassTests {
    typealias Ground = PaneGroundCoversPaneTests
    typealias Counts = KeyResizeLayoutsPerFrameTests

    /// Where the layout is shown.
    enum Host: String, CaseIterable, CustomStringConvertible {
        /// The app's window: `ShellWindow`, its style, and `WindowRootView` showing the layout in its main pane.
        case appWindow
        /// The control: the same window with a plain content view and the layout by its autoresizing mask.
        case titledPlain

        var description: String { rawValue }

        func window(for layout: LayoutRootView) -> NSWindow {
            let rect = NSRect(x: 0, y: 0, width: 1200, height: 800)
            let window = ShellWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            switch self {
            case .appWindow:
                let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
                window.contentView = root
                root.layoutSubtreeIfNeeded()
                root.show(layout)
            case .titledPlain:
                let content = NSView(frame: rect)
                window.contentView = content
                layout.frame = content.bounds
                layout.autoresizingMask = [.width, .height]
                content.addSubview(layout)
            }
            return window
        }
    }

    /// The views of `window` that take part in Auto Layout (own constraints, or not translating their autoresizing mask).
    static func constraintViews(in window: NSWindow) -> String {
        var found: [String] = []
        var stack = [window.contentView?.superview].compactMap { $0 }
        while let view = stack.popLast() {
            let own = view.constraints.count
            if own > 0 || !view.translatesAutoresizingMaskIntoConstraints {
                found.append("\(type(of: view))(c\(own)\(view.translatesAutoresizingMaskIntoConstraints ? "" : " noAR") in \(view.superview.map { "\(type(of: $0))" } ?? "-"))")
            }
            stack.append(contentsOf: view.subviews)
        }
        return found.prefix(40).joined(separator: ", ")
    }

    /// Per pane view class, how many of those views have autoresizing-mask constraints installed in their superview.
    static func autoresizingConstrained(under root: NSView) -> String {
        var counts: [String: (with: Int, all: Int)] = [:]
        var stack = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard view is PaneHostView || view is TerminalSurfaceView || view is LayoutRootView || view is ScreenContentView else { continue }
            let name = String(describing: type(of: view))
            let own = view.superview?.constraints.contains { ($0.firstItem as? NSView) === view && String(describing: type(of: $0)).contains("Autoresizing") } ?? false
            counts[name, default: (0, 0)].all += 1
            if own { counts[name, default: (0, 0)].with += 1 }
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.with)/\($0.value.all)" }.joined(separator: ", ")
    }

    /// Diagnosis: the layout's frame against its superview's bounds, and each pane host's frame.
    static func frames(_ root: LayoutRootView) -> String {
        let hosts = root.context.hosts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\(NSStringFromRect($0.value.frame))" }
        return "layout \(NSStringFromRect(root.frame)) in \(root.superview.map { NSStringFromRect($0.bounds) } ?? "-"), hosts \(hosts)"
    }

    @Test(arguments: Host.allCases)
    func aKeyResizeSpringFrameRunsNoWindowPass(host: Host) throws {
        LayoutPassGuard.shared.install()
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2", host: host.window(for:))
        defer { rig.close() }
        let frameView = try #require(rig.window.contentView?.superview)
        let frameClass = String(describing: type(of: frameView))
        rig.root.layoutSubtreeIfNeeded()
        rig.commit()
        rig.window.layoutIfNeeded()

        #expect(PaneResize.press("p2", .right, model: rig.model, view: rig.root))
        rig.window.layoutIfNeeded() // the key's turn: its own commit
        var extra: [String] = []
        var framePasses = 0
        var frames = 0
        while frames < 240 {
            let before = Counts.sizes(under: frameView)
            let moving = rig.frame()
            // The CA commit at the end of the frame's turn: AppKit's window pass.
            let start = Counts.calls()
            rig.window.layoutIfNeeded()
            let laid = Counts.since(start)
            frames += 1
            var resized: [String: Int] = [:]
            for (id, entry) in Counts.sizes(under: frameView) where before[id]?.size != entry.size { resized[entry.viewClass, default: 0] += 1 }
            framePasses += laid[frameClass, default: 0]
            for (viewClass, count) in laid where count > resized[viewClass, default: 0] {
                extra.append("frame \(frames): \(viewClass) \(count)x (\(resized[viewClass, default: 0]) resized)")
            }
            if !moving { break }
        }
        let found = "host \(host): \(frames) frames, \(frameClass) passes \(framePasses), autoresizing constraints "
            + "[\(Self.autoresizingConstrained(under: frameView))], Auto Layout views [\(Self.constraintViews(in: rig.window))], "
            + "extra \(extra.count): \(extra.prefix(8))"
        print("M2DIAG \(found)")
        let settled = Self.frames(rig.root)
        rig.window.setContentSize(NSSize(width: 1000, height: 700))
        rig.window.layoutIfNeeded()
        rig.root.layoutSubtreeIfNeeded()
        print("M2FRAMES host \(host): after spring [\(settled)], after window resize to 1000x700 [\(Self.frames(rig.root))]")
        #expect(frames > 2, "the press did not spring")
        #expect(framePasses == 0, "the window's frame view laid out \(framePasses)x in \(frames) spring frames. \(found)")
        #expect(extra.isEmpty, "\(extra.count) window-pass layouts of views whose size did not change. \(found)")
    }

    /// Each pane's terminal against its clip: the frames the pane tree places stay right with the tree out of the
    /// window's engine.
    static func misplaced(_ root: LayoutRootView) -> [String] {
        root.context.hosts.compactMap { pane, host in
            guard let content = host.clipView.subviews.first else { return "\(pane.rawValue): no content" }
            return content.frame.size == host.clipView.bounds.size ? nil
                : "\(pane.rawValue): content \(NSStringFromRect(content.frame)) in clip \(NSStringFromRect(host.clipView.bounds))"
        }.sorted()
    }

    /// The pane tree leaves the window's Auto Layout engine (`placeSubtreeByFrame`) and keeps every frame right: a
    /// view placed by its autoresizing mask still follows its container, a view pinned by constraints in a terminal
    /// (copy mode's badge) does not move the terminal, and a window resize reflows the panes.
    @Test func thePaneTreeOutOfTheEngineKeepsItsFrames() throws {
        LayoutPassGuard.shared.install()
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2", host: Host.appWindow.window(for:))
        defer { rig.close() }
        rig.root.layoutSubtreeIfNeeded()
        rig.commit()
        rig.window.layoutIfNeeded()
        let hosts = rig.root.context.hosts.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)
        try #require(hosts.count == 2)
        let first = try #require(hosts[0].clipView.subviews.first), second = try #require(hosts[1].clipView.subviews.first)
        #expect(!first.translatesAutoresizingMaskIntoConstraints && !hosts[0].translatesAutoresizingMaskIntoConstraints)
        // A view placed by its mask, added after the pane mounted.
        let filler = NSView(frame: first.bounds)
        filler.autoresizingMask = [.width, .height]
        first.addSubview(filler)
        // A badge pinned by constraints in the other terminal, as copy mode pins its badge.
        let badge = NSTextField(labelWithString: "COPY")
        badge.translatesAutoresizingMaskIntoConstraints = false
        second.addSubview(badge)
        NSLayoutConstraint.activate([badge.topAnchor.constraint(equalTo: second.topAnchor, constant: 8),
                                     badge.trailingAnchor.constraint(equalTo: second.trailingAnchor, constant: -8)])
        rig.window.layoutIfNeeded()
        #expect(Self.misplaced(rig.root).isEmpty, "after the badge: \(Self.misplaced(rig.root))")

        #expect(PaneResize.press("p2", .right, model: rig.model, view: rig.root))
        rig.window.layoutIfNeeded()
        var frames = 0
        while frames < 240 {
            let moving = rig.frame()
            rig.window.layoutIfNeeded()
            frames += 1
            if !moving { break }
        }
        let afterSpring = "\(Self.frames(rig.root)), filler \(NSStringFromRect(filler.frame)) in \(NSStringFromRect(first.bounds)), "
            + "badge \(NSStringFromRect(badge.frame)) in \(NSStringFromRect(second.bounds))"
        print("M2FRAMES spring: \(afterSpring)")
        #expect(frames > 2, "the press did not spring")
        #expect(Self.misplaced(rig.root).isEmpty, "after the spring: \(Self.misplaced(rig.root)). \(afterSpring)")
        #expect(filler.frame.size == first.bounds.size, "the masked view did not follow its terminal. \(afterSpring)")
        #expect(abs(badge.frame.maxX - (second.bounds.maxX - 8)) < 1, "the pinned badge did not follow its terminal. \(afterSpring)")

        let before = hosts.map(\.frame.width)
        rig.window.setContentSize(NSSize(width: 1000, height: 700))
        rig.window.layoutIfNeeded()
        rig.root.layoutSubtreeIfNeeded()
        let afterResize = "\(Self.frames(rig.root)), filler \(NSStringFromRect(filler.frame)) in \(NSStringFromRect(first.bounds))"
        print("M2FRAMES resize: \(afterResize)")
        #expect(rig.root.frame.size == rig.root.superview?.bounds.size, "the layout did not follow the window. \(afterResize)")
        #expect(zip(before, hosts.map(\.frame.width)).allSatisfy { $0 > $1 }, "the panes did not narrow. \(afterResize)")
        #expect(Self.misplaced(rig.root).isEmpty, "after the window resize: \(Self.misplaced(rig.root)). \(afterResize)")
        #expect(filler.frame.size == first.bounds.size, "the masked view did not follow after the resize. \(afterResize)")
    }
}
