import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import Foundation
import Testing

/// cmuxterm-hq#19032 cause 1 (fleet job 9c35cd0a, half-empty `move_to_split_right`): Move Tab to New Split showed one
/// committed frame with a terminal of a pane the move resizes already at its new width (layer and IOSurface 456 wide)
/// in its pane at the old width (684), then the panes a frame later. The model path the bench drives (the daemon's
/// `tab.moveToNewSplit`), not a layout the test applies (`StructuralSnapSurfaceHoldTests` does that one, and it holds).
///
/// A | B, B's tab moved to a new split on its right: A | B | C, every pane resized. Every Core Animation commit from the
/// move to its settle is read right after it (the run loop's `beforeWaiting`, after the commit's observer), as the
/// screen shows it: no terminal's layer may change size in a commit in which its pane keeps its size, and no shown
/// terminal's layer may be at another size than its host's area.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct MoveToNewSplitCommitFrameTests {
    private final class Commits {
        struct Seen { var layer: CGSize; var pane: ObjectIdentifier; var paneSize: CGSize }
        var last: [ObjectIdentifier: Seen] = [:]
        var lines: [String] = []
        var early: [String] = []
        var unfit: [String] = []
        var count = 0
        var moving = false
    }

    @Test func aTerminalTakesItsNewSizeInTheCommitThatShowsItsPanesNewSize() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let controller = try #require(services.windows.active)
            let workspace = try await MoveToNewWindowTests.newWorkspace(services)
            controller.state.showWorkspace(workspace.id)
            let source = try #require(workspace.screens.first?.panes.first)
            let second = try await connection.newTab(in: source.handle)
            try await PasswordManagerRouteTests.until({
                controller.state.workspaceID == workspace.id && source.tabs.count == 2 && services.daemon.store.tab(surface: second.surface) != nil
            })
            // A | B: the second tab to a new split on the right.
            try await Self.move(second.surface, services, panes: 2, in: workspace)
            let paneB = try #require(workspace.screens.flatMap(\.panes).first { $0.id != source.id })
            let third = try await connection.newTab(in: paneB.handle)
            try await PasswordManagerRouteTests.until({ paneB.tabs.count == 2 && services.daemon.store.tab(surface: third.surface) != nil })
            try await Task.sleep(for: .milliseconds(600))
            let window = try #require(controller.window)
            let presenter = TerminalFramePresenter.forWindow(window)
            let commits = Commits()
            presenter.placeHook = { view, frame in
                guard commits.moving, frame.size != view.bounds.size else { return }
                let stack = Thread.callStackSymbols.dropFirst(1).prefix(18).joined(separator: "\n    ")
                print("SPLIT MOVE place commit \(commits.count) \(Self.name(view)): \(Self.text(view.bounds.size)) -> \(Self.text(frame.size)) "
                      + "screens \(Self.screens(window))\n    \(stack)")
            }
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                              true, 2_000_001) { _, _ in
                MainActor.assumeIsolated { if commits.moving { Self.read(window, into: commits) } }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            defer {
                CFRunLoopObserverInvalidate(observer)
                presenter.placeHook = nil
            }
            Self.read(window, into: commits) // the layout before the move
            commits.moving = true
            try await Self.move(third.surface, services, panes: 3, in: workspace)
            try await Task.sleep(for: .milliseconds(800))
            commits.moving = false
            for line in commits.lines { print("SPLIT MOVE \(line)") }
            #expect(commits.early.isEmpty, "\(commits.early.count) commits showed a terminal at a new size in its pane at its old one: \(commits.early)")
            #expect(commits.unfit.isEmpty, "\(commits.unfit.count) commits showed a terminal's layer at another size than its host's area: \(commits.unfit)")
        }
    }

    private static func move(_ surface: SurfaceID, _ services: AppServices, panes: Int, in workspace: WorkspaceModel) async throws {
        let tab = try #require(services.daemon.store.tab(surface: surface))
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), arguments: ["direction": .string("right")], origin: .user)
        #expect(services.registry.perform("tab.moveToNewSplit", invocation: invocation))
        try await PasswordManagerRouteTests.until({ workspace.screens.flatMap(\.panes).count == panes },
                                                   report: { "panes \(workspace.screens.flatMap(\.panes).map { $0.tabs.map(\.id) })" })
    }

    /// Each shown screen's held snap and pane frames (shown rect, target, host frame).
    private static func screens(_ window: NSWindow) -> String {
        guard let root = window.contentView else { return "" }
        var out: [String] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard let screen = view as? ScreenContentView, !screen.isHiddenOrHasHiddenAncestor else { continue }
            let panes = screen.paneFrames.sorted { $0.key.rawValue < $1.key.rawValue }.map { pane, frame in
                "\(pane.rawValue.suffix(4)) rect \(rect(frame.rect)) target \(rect(frame.targetRect)) host \(screen.context.hosts[pane].map { rect($0.frame) } ?? "-")"
            }
            out.append("[snap waits \(screen.frameInput.snapWaitsForContent), holds \(screen.context.holdsPresentations): \(panes.joined(separator: "; "))]")
        }
        return out.joined(separator: " ")
    }

    private static func rect(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))" }

    /// One commit as the screen shows it: each shown terminal's layer, its host's area and its pane's size.
    private static func read(_ window: NSWindow, into commits: Commits) {
        guard let root = window.contentView else { return }
        let index = commits.count
        commits.count += 1
        commits.lines.append("commit \(index) screens \(screens(window))")
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard let surface = view as? TerminalSurfaceView, !surface.isHiddenOrHasHiddenAncestor,
                  let host = surface.superview as? TerminalHostView, let layer = surface.layer else { continue }
            let pane = sequence(first: host as NSView, next: \.superview).first { $0 is PaneHostView } as? PaneHostView
            let paneSize = pane?.frame.size ?? .zero
            let area = host.surfaceSize(forHostSize: host.bounds.size)
            let scale = layer.contentsScale
            let line = "commit \(index) \(name(surface)): pane \(pane.map { $0.pane.rawValue } ?? "-") \(text(paneSize)), host \(text(host.bounds.size)), "
                + "area \(text(area)), layer \(text(layer.bounds.size)), presenter \(TerminalFramePresenter.forWindow(window).debugState(of: surface)), "
                + "ahead \(surface.frameOwnership.ahead.map(text) ?? "none"), in flight \(surface.frameOwnership.inFlight.map(text) ?? "none")"
            commits.lines.append(line)
            let id = ObjectIdentifier(surface)
            let seen = Commits.Seen(layer: layer.bounds.size, pane: pane.map(ObjectIdentifier.init) ?? id, paneSize: paneSize)
            defer { commits.last[id] = seen }
            // Nothing of it shows in a pane with no size yet (a pane the move made, before the frame that shows it).
            guard paneSize.width >= 1, paneSize.height >= 1 else { continue }
            if area.width >= 1, area.height >= 1,
               abs(layer.bounds.width - area.width) * scale > 1 || abs(layer.bounds.height - area.height) * scale > 1 {
                commits.unfit.append(line)
            }
            if let before = commits.last[id], before.pane == seen.pane, before.paneSize == paneSize, before.layer != seen.layer {
                commits.early.append(line + " (was \(text(before.layer)))")
            }
        }
    }

    private static func name(_ view: TerminalSurfaceView) -> String { String(UInt(bitPattern: ObjectIdentifier(view).hashValue), radix: 16) }
    static func text(_ size: CGSize) -> String { "\(size.width)x\(size.height)" }
}
