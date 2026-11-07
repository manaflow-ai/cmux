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
/// particular not the window's frame view. RESIZE P0 9: a titled `ShellWindow` whose content view is the layout itself
/// has no Auto Layout view and no frame-view pass, so the window's root view is part of the rule.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct SpringFrameNoWindowPassTests {
    typealias Ground = PaneGroundCoversPaneTests
    typealias Counts = KeyResizeLayoutsPerFrameTests

    /// Where the layout is shown.
    enum Host: String, CaseIterable, CustomStringConvertible {
        /// The app's window: `ShellWindow`, its style, and `WindowRootView` showing the layout in its main pane.
        case appWindow
        /// Diagnosis: a titled `ShellWindow` whose content view is a plain view with the layout by frame, and one
        /// Auto Layout view beside it (a label pinned to the content view's corner).
        case constraintSibling
        /// Diagnosis: the layout by autoresizing mask in a container that Auto Layout pins to the content view's edges.
        case constraintContainer
        /// Diagnosis: the layout in a container placed by frame (autoresizing mask) that a constraint of an Auto Layout
        /// sibling refers to (the label's leading edge pinned to the container's).
        case constraintReferencedContainer
        /// Diagnosis (control): a plain content view with the layout by autoresizing mask, no constraint in the window.
        case titledPlain
        /// Diagnosis: a sibling of the layout (placed by frame) holds a label pinned inside it: the constraints live in
        /// the sibling's subtree only, as the sidebar's do.
        case constraintInSiblingSubtree
        /// Diagnosis: as `constraintSibling`, with the layout not translating its mask and no constraint of its own.
        case constraintSiblingLayoutNoMask

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
            case .constraintSibling:
                let content = NSView(frame: rect)
                window.contentView = content
                layout.frame = content.bounds
                layout.autoresizingMask = [.width, .height]
                content.addSubview(layout)
                let label = NSTextField(labelWithString: "x")
                label.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(label)
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                                             label.topAnchor.constraint(equalTo: content.topAnchor)])
            case .constraintContainer:
                let content = NSView(frame: rect)
                window.contentView = content
                let container = NSView(frame: rect)
                container.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(container)
                NSLayoutConstraint.activate([container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                                             container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                             container.topAnchor.constraint(equalTo: content.topAnchor),
                                             container.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
                content.layoutSubtreeIfNeeded()
                layout.frame = container.bounds
                layout.autoresizingMask = [.width, .height]
                container.addSubview(layout)
            case .constraintReferencedContainer:
                let content = NSView(frame: rect)
                window.contentView = content
                let container = NSView(frame: rect)
                container.autoresizingMask = [.width, .height]
                content.addSubview(container)
                layout.frame = container.bounds
                layout.autoresizingMask = [.width, .height]
                container.addSubview(layout)
                let label = NSTextField(labelWithString: "x")
                label.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(label)
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                                             label.topAnchor.constraint(equalTo: content.topAnchor)])
            case .titledPlain:
                let content = NSView(frame: rect)
                window.contentView = content
                layout.frame = content.bounds
                layout.autoresizingMask = [.width, .height]
                content.addSubview(layout)
            case .constraintInSiblingSubtree:
                let content = NSView(frame: rect)
                window.contentView = content
                layout.frame = content.bounds
                layout.autoresizingMask = [.width, .height]
                content.addSubview(layout)
                let side = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
                content.addSubview(side)
                let label = NSTextField(labelWithString: "x")
                label.translatesAutoresizingMaskIntoConstraints = false
                side.addSubview(label)
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: side.leadingAnchor),
                                             label.topAnchor.constraint(equalTo: side.topAnchor)])
            case .constraintSiblingLayoutNoMask:
                let content = NSView(frame: rect)
                window.contentView = content
                layout.translatesAutoresizingMaskIntoConstraints = false
                layout.frame = content.bounds
                content.addSubview(layout)
                let label = NSTextField(labelWithString: "x")
                label.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(label)
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                                             label.topAnchor.constraint(equalTo: content.topAnchor)])
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
        #expect(frames > 2, "the press did not spring")
        #expect(framePasses == 0, "the window's frame view laid out \(framePasses)x in \(frames) spring frames. \(found)")
        #expect(extra.isEmpty, "\(extra.count) window-pass layouts of views whose size did not change. \(found)")
    }
}
