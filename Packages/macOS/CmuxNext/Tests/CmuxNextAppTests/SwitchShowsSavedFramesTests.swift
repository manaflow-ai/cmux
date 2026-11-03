import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import Foundation
import IOSurface
import Testing

/// SWITCH FRAMES item 2 (STATUS 8158, the lead 2026-11-03): a Cmd-digit switch back to a workspace whose terminals the
/// warm set evicted made each pane a new terminal, one new surface per display frame (`ContentPresentationScheduler`).
/// The panes that waited for their surface showed nothing (12 panes: up to 12 frames of empty panes), and a pane that got
/// its surface showed its saved frame on a second layer over it (`TerminalFrameHold`'s held view: +46 ms of Core
/// Animation commit in a 12-pane switch, #32941). Chrome shows a tab's last frame at once and the renderer catches up.
///
/// Each revealed pane shows its saved frame from the first frame after the key, on exactly one layer: the frame alone
/// while the pane waits for its terminal, then the terminal's own surface layer, whose live frame replaces it in place.
/// Never zero layers with a frame (an empty pane), never two (a layer over the terminal).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SwitchShowsSavedFramesTests {
    private typealias Terminal = (pane: String, tab: String, surface: SurfaceID)

    /// The layers that show a frame under `host` in the frame Core Animation commits at the end of this turn: the own
    /// layer of each shown view under `host` whose contents are a terminal's IOSurface or a picture. Read from the view
    /// tree, not from `host.layer.sublayers`: AppKit attaches a view added in this turn to the layer tree only in its
    /// display cycle before that commit (`_buildLayerTree`), so a layer walk in the turn misses every view the switch
    /// added (both arms).
    static func frameLayers(in host: NSView) -> [CALayer] {
        func walk(_ view: NSView) -> [CALayer] {
            guard !view.isHidden else { return [] }
            let own: [CALayer] = view.layer.flatMap { layer in
                layer.contents.map { CFGetTypeID($0 as CFTypeRef) }.flatMap { $0 == IOSurfaceGetTypeID() || $0 == CGImage.typeID ? [layer] : nil }
            } ?? []
            return own + view.subviews.flatMap(walk)
        }
        return host.subviews.flatMap(walk)
    }

    /// A frame for a failure message: an IOSurface by id and seed (its draw count), a picture (a frame from the last quit
    /// or the on-disk keeper, older than an evicted terminal's last frame), or nothing.
    static func describe(_ contents: Any?) -> String {
        guard let contents else { return "nothing" }
        let object = contents as CFTypeRef
        if CFGetTypeID(object) == IOSurfaceGetTypeID() {
            let surface = unsafeDowncast(object, to: IOSurface.self)
            return "iosurface \(Unmanaged.passUnretained(surface).toOpaque()) seed \(surface.seed)"
        }
        return CFGetTypeID(object) == CGImage.typeID ? "picture (launch or keeper frame)" : "other"
    }

    @Test func aSwitchBackToEvictedTerminalsShowsEachPanesSavedFrameOnOneLayerFromTheFirstFrame() async throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: true)
            // A warm set that keeps both hidden terminals while the test reads their frames; the later switches push them
            // out of it as a full warm set does on a Cmd-1..9 cycle (least recently hidden first), and their panes stay
            // parked as they do then. Never a smaller cap to force it: a cap that falls evicts at once (the memory-pressure
            // path) and keeps no frame.
            let budget = services.cache.warmBudget
            services.cache.setWarmBudget(WarmSetBudget(terminalCapacity: 4))
            defer { services.cache.setWarmBudget(budget) }

            // A workspace with two terminals side by side.
            let id = try #require(await services.windows.createWorkspace(into: controller.state.id))
            @MainActor func terminals() -> [Terminal] {
                guard controller.workspaceContent?.workspace.id == id, let content = controller.workspaceContent else { return [] }
                return content.panes.values.compactMap { pane in
                    guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
                          let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                    else { return nil }
                    return (pane.paneKey, tab, model.surface)
                }
            }
            try await PinnedPageTests.until({
                if controller.workspaceContent?.workspace.id != id { services.windows.show(workspaceID: id, in: controller.state) }
                return terminals().count == 1
            }, report: { "waiting for the workspace's terminal" })
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: terminal))
            try await PinnedPageTests.until({ terminals().count == 2 }, report: { "waiting for the split's terminal" })
            let shells = terminals()
            for shell in shells {
                try await connection.send(shell.surface, text: "echo saved$((3*3))\r")
                let shown = try? await connection.request(WaitForTextRequest(surface: shell.surface, pattern: "saved9", timeoutMs: 20_000), timeout: .seconds(25))
                try #require(shown?.matched == true, "the shell of \(shell.tab) never answered")
            }
            // Each terminal presents the frame with its output (the frame the warm set keeps).
            try await PinnedPageTests.until({
                shells.allSatisfy { services.cache.terminals[$0.tab]?.session.surfaceHasContent == true
                    && services.cache.terminals[$0.tab]?.session.surfaceView.presentedFrame != nil }
            }, report: { "waiting for both terminals' frames" })
            try await Task.sleep(for: .milliseconds(300)) // the frame with the echo lands

            // Other workspaces show in turn. The first hides both terminals (both stay warm, paused: they draw nothing
            // more, so the frame each shows now is the one its eviction keeps; a frame read while they were on screen could
            // be replaced by a later draw, such as a cursor blink). The next two push both out of the warm set.
            @MainActor func showAnotherWorkspace() async throws {
                let other = try #require(await services.windows.createWorkspace(into: controller.state.id))
                try await PinnedPageTests.until({
                    if controller.workspaceContent?.workspace.id != other { services.windows.show(workspaceID: other, in: controller.state) }
                    return controller.workspaceContent?.workspace.id == other && controller.workspaceContent?.panes.isEmpty == false
                }, report: { "waiting for another workspace" })
            }
            try await showAnotherWorkspace()
            // Paused: the surface draws nothing more (suspended, hidden or parked: `diagnostics.drawing` false).
            try await PinnedPageTests.until({ shells.allSatisfy { services.cache.terminals[$0.tab]?.session.diagnostics.drawing == false } },
                                            report: {
                let each = shells.map { shell -> String in
                    guard let session = services.cache.terminals[shell.tab]?.session else { return "\(shell.tab): evicted" }
                    let d = session.diagnostics
                    return "\(shell.tab): drawing \(String(describing: d.drawing)) pause \(String(describing: d.pause)) suspended \(d.renderingSuspended)"
                }
                return "the hidden terminals are not warm and paused: \(each) \(services.cache.lastFrames.report)"
            })
            // The newest frame each terminal drew before it hid: its presented frame once paused, stable for 300 ms (a
            // frame in flight at the pause may still land; the read waits it out).
            var saved: [String: IOSurface] = [:]
            var stableSince = ContinuousClock.now
            let stableBy = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < stableBy {
                var now: [String: IOSurface] = [:]
                for shell in shells { now[shell.pane] = services.cache.terminals[shell.tab]?.session.surfaceView.presentedFrame }
                if now.count != shells.count || now.contains(where: { saved[$0.key] !== $0.value }) { saved = now; stableSince = .now }
                if saved.count == shells.count, ContinuousClock.now - stableSince >= .milliseconds(300) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(saved.count == shells.count, "a hidden terminal has no frame")
            // More workspaces, each with a terminal of its own, until the warm set has pushed both of this one's out.
            for _ in 0..<8 where !shells.allSatisfy({ !services.cache.hasContent(for: $0.tab) }) {
                try await showAnotherWorkspace()
            }
            try await PinnedPageTests.until({ shells.allSatisfy { !services.cache.hasContent(for: $0.tab) } },
                                            report: { "the warm set kept a hidden terminal: \(services.cache.lastFrames.report)" })
            for shell in shells {
                let stored = try #require(services.cache.lastFrames[shell.tab], "no saved frame of \(shell.tab): \(services.cache.lastFrames.report)")
                let kept = "stored \(Self.describe(stored.surface)), newest at hide \(Self.describe(saved[shell.pane]))"
                #expect(stored.surface === saved[shell.pane], "the store kept another frame than the newest one \(shell.tab) drew before it hid: \(kept)")
            }

            // The switch's turn: the frame Core Animation commits at its end is the first frame after the key.
            services.windows.show(workspaceID: id, in: controller.state)
            let content = try #require(controller.workspaceContent)
            #expect(content.workspace.id == id, "the window did not show the workspace in this turn")
            // What a failure reports: each pane's state and the saved-frame store.
            @MainActor func state(_ shell: Terminal) -> String {
                guard let pane = content.paneController(key: shell.pane) else { return "\(shell.pane): no pane" }
                let session = services.cache.terminals[shell.tab]?.session
                let shown: String = session?.surfaceView.layer?.contents.map { CFGetTypeID($0 as CFTypeRef) == IOSurfaceGetTypeID() ? "iosurface" : "other" } ?? "nil"
                return "\(shell.pane): presence \(pane.presence) suspended \(pane.isSuspended) hosts \(pane.view.hostsContent) session \(session != nil)"
                    + " held \(session?.showsHeldFrame ?? false) contents \(shown) stored \(services.cache.lastFrames[shell.tab] != nil)"
            }
            for shell in shells {
                let pane = try #require(content.paneController(key: shell.pane))
                let layers = Self.frameLayers(in: pane.view.contentHost)
                let kinds = layers.map { String(describing: type(of: $0)) }
                #expect(layers.count == 1, "pane \(shell.pane) shows its frame on \(layers.count) layers in the first frame after the key (0: an empty pane; 2: a layer over its terminal): \(kinds); \(state(shell)); \(services.cache.lastFrames.report)")
                let shownFirst = "shows \(Self.describe(layers.first?.contents)), newest at hide \(Self.describe(saved[shell.pane])); \(services.cache.lastFrames.report)"
                #expect(layers.first.map { ($0.contents as CFTypeRef?) === saved[shell.pane] } == true,
                        "pane \(shell.pane) does not show the newest frame at hide time in the first frame after the key: \(shownFirst)")
                if let session = services.cache.terminals[shell.tab]?.session, session.view.isDescendant(of: pane.view.contentHost) {
                    #expect(layers.first === session.surfaceView.layer,
                            "pane \(shell.pane)'s saved frame is on a layer over its terminal, not the terminal's own surface layer")
                }
            }

            // Each later frame until both terminals show their live content: one layer with a frame per pane.
            var violations: [String] = []
            let by = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < by {
                try await Task.sleep(for: .milliseconds(2))
                var live = 0
                for shell in shells {
                    guard let pane = content.paneController(key: shell.pane) else { continue }
                    let layers = Self.frameLayers(in: pane.view.contentHost)
                    if layers.count != 1, violations.count < 8 { violations.append("\(layers.count) layers; \(state(shell))") }
                    if let session = services.cache.terminals[shell.tab]?.session, session.view.isDescendant(of: pane.view.contentHost),
                       let frame = session.surfaceView.presentedFrame, frame !== saved[shell.pane], !session.showsHeldFrame {
                        live += 1
                    } else if layers.count == 1, (layers[0].contents as CFTypeRef?) !== saved[shell.pane], violations.count < 8 {
                        // Before its live content: the newest frame at hide time, never an older one (stale content) or an empty grid.
                        violations.append("not the newest frame at hide time: \(Self.describe(layers[0].contents)), newest \(Self.describe(saved[shell.pane])); \(state(shell))")
                    }
                }
                if live == shells.count { break }
            }
            #expect(violations.isEmpty, "a frame between the switch and the live content showed a pane on other than one layer, or other than the newest frame at hide time: \(violations)")
            var screens: [String] = []
            for shell in shells { screens.append((try? await connection.request(ReadScreenRequest(surface: shell.surface), timeout: .seconds(5)))?.text ?? "") }
            #expect(screens.allSatisfy { $0.contains("saved9") }, "a terminal lost its content after the switch: \(screens)")
        }
    }

    /// The second fault of the same switch (the cause of #32941's +46 ms of Core Animation commit): a pane whose new
    /// terminal session already exists when the switch reveals it showed the saved frame on a held view over the
    /// terminal's surface (`TerminalFrameHold`), and the surface drew its empty grid under it until the replay came: two
    /// layers with a frame in that pane. The saved frame is the surface's own contents, one layer, until the terminal's
    /// first content is drawn on that same layer.
    @Test func aRevealedSessionShowsItsSavedFrameOnItsOwnLayerNotOnALayerOverIt() async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        window.contentView = host
        window.orderFrontRegardless()
        let io = ScriptedTerminalIO(), freshIO = ScriptedTerminalIO()
        defer {
            io.finish()
            freshIO.finish()
            window.close()
        }
        // A terminal with output, hidden by a switch, then evicted by the warm set (its saved frame stays).
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        session.view.frame = host.bounds
        host.addSubview(session.view)
        session.view.layoutSubtreeIfNeeded()
        io.send(.output(Data("\u{1b}[2J\u{1b}[Hsaved frame\r\nline 2\r\n".utf8)))
        try await EvictedTerminalRevealFrameTests.drawn(session)
        try await Task.sleep(for: .milliseconds(200))
        let saved = try #require(session.surfaceView.presentedFrame)
        session.isRenderingSuspended = true
        var frames = TerminalLastFrames()
        frames.evict(session, key: "tab", capacity: 8, atOnce: false)
        session.view.removeFromSuperview()
        session.close()
        try #require(frames["tab"] != nil, "setup: no saved frame: \(frames.report)")

        // The switch's turn, as the cache reveals it: the new session shows the saved frame, then the pane installs it.
        let fresh = TerminalSession(io: freshIO)
        defer { fresh.close() }
        fresh.isRenderingSuspended = true
        frames.show("tab", on: fresh)
        fresh.isRenderingSuspended = false
        fresh.view.frame = host.bounds
        host.addSubview(fresh.view)
        fresh.view.layoutSubtreeIfNeeded()
        #expect(fresh.diagnostics.lastFrameHolds == 1, "the revealed session showed no saved frame: \(frames.report)")

        // Every frame until its content is drawn: one layer with a frame, and before the content, the saved one.
        var violations: [String] = []
        func sample(_ phase: String) {
            let layers = Self.frameLayers(in: host)
            guard layers.count != 1, violations.count < 8 else { return }
            violations.append("\(phase): \(layers.count) layers (\(layers.map { $0 === fresh.surfaceView.layer ? "surface" : "over" }))")
        }
        let quiet = ContinuousClock.now.advanced(by: .milliseconds(600)) // no content yet: the surface may draw its empty grid
        while ContinuousClock.now < quiet {
            sample("before content")
            try await Task.sleep(for: .milliseconds(4))
        }
        let before = Self.frameLayers(in: host)
        #expect(before.count == 1 && (before.first?.contents as CFTypeRef?) === saved,
                "before its content the pane does not show the saved frame alone: \(before.count) layers")
        freshIO.send(.output(Data("\u{1b}[2J\u{1b}[Hlive content\r\n".utf8)))
        let by = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < by {
            sample("after content")
            if let shown = fresh.surfaceView.presentedFrame, shown !== saved, !fresh.showsHeldFrame { break }
            try await Task.sleep(for: .milliseconds(4))
        }
        #expect(violations.isEmpty, "the revealed pane showed other than one layer with a frame: \(violations)")
        #expect(Self.frameLayers(in: host).first === fresh.surfaceView.layer, "the live frame is not on the terminal's own layer")
    }
}
