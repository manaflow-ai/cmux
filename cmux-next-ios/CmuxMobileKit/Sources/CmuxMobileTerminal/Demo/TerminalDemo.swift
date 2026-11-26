#if os(iOS) && DEBUG
import CmuxMobileDesign
import SwiftUI
import UIKit

/// DEBUG only. Launch with `-CmuxMobileTerminalDemo` (optionally
/// `-CmuxMobileTerminalDemoPhases scroll,keyboard,tui,vim,attachments,artifacts`) to
/// open a mock terminal and drive it: scroll flings, keyboard show and hide,
/// composer typing, TUI mode with the keyboard, the joystick, attachments and
/// the artifacts sheet. Each phase start is appended to
/// `Documents/terminal-demo-timeline.txt` (wall clock) to line up with a recording.
public struct TerminalDemoRoot: View {
    @State private var model: TerminalModel
    @State private var host: TerminalTabHost

    public init() {
        // `-CmuxMobileTerminalDemoLight`: a light terminal theme (the Mac's
        // Solarized Light), set before the terminal engine reads its colors,
        // for this launch only: the next test's launch keeps its own theme.
        if CommandLine.arguments.contains("-CmuxMobileTerminalDemoLight") {
            CmuxMobileMacTheme.shared.apply(CmuxMobileMacAppearance(theme: .init(
                background: "#fdf6e3", foreground: "#657b83",
                palette: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5"],
                accent: "blue")), keep: false)
        }
        // `-CmuxMobileTerminalDemoAttach`: the phone attaches into htop
        // already running on a Mac pane of 120x40, the Mac answering the
        // attach and each resize a round trip later (`-CmuxMobileTerminalDemoMac
        // -CmuxMobileTerminalDemoMacMs N`, default 60), with the attach in series
        // under `-CmuxMobileTerminalDemoAttachSerial` (TerminalAttachFirstFrameUITests).
        let attach = Self.attachRequested
            ? MockTerminalSession(playsIntro: false, macResize: Self.macResize ?? .milliseconds(60), attachesTo: (120, 40),
                                  attachesInSeries: CommandLine.arguments.contains("-CmuxMobileTerminalDemoAttachSerial")) : nil
        let session: any TerminalSession
        var altMac: MacPaneMockSession?
        let phases = TerminalDemoDriver.requestedPhases ?? []
        if let attach {
            session = attach
        } else if phases.contains("projection") || phases.contains("altproj") {
            // A Mac pane of 120x40 (or `-CmuxMobileTerminalDemoMacGrid 39x26`, a
            // pane narrower than the phone), through the session the app builds
            // for a Mac terminal; `-CmuxMobileTerminalDemoMacProgram claude`:
            // Claude Code inline in it. `altproj`: htop already running in it, and
            // the Mac answering a claim a round trip later
            // (`-CmuxMobileTerminalDemoMacLatencyMs`, default 60: LTE), or never
            // (`-CmuxMobileTerminalDemoMacKeepsSize YES`: Prefer this Mac).
            let defaults = UserDefaults.standard
            let grid = (defaults.string(forKey: "CmuxMobileTerminalDemoMacGrid") ?? "").split(separator: "x").compactMap { Int($0) }
            let alt = phases.contains("altproj")
            let latency = alt ? (defaults.object(forKey: "CmuxMobileTerminalDemoMacLatencyMs") as? Int ?? 60) : 0
            let mac = MacPaneMockSession(columns: grid.count == 2 ? grid.first ?? 120 : 120, rows: grid.count == 2 ? grid.last ?? 40 : 40,
                                         program: alt ? "htop" : defaults.string(forKey: "CmuxMobileTerminalDemoMacProgram"),
                                         latency: .milliseconds(latency),
                                         keepsSize: alt && defaults.bool(forKey: "CmuxMobileTerminalDemoMacKeepsSize"))
            if alt {
                altMac = mac
                // `altproj` shows Settings → Terminal → Zoom Full-Screen Apps on
                // (registered, never saved; a launch argument still wins).
                defaults.register(defaults: [CmuxMobilePreferences.Key.terminalZoomFullScreenApps: true])
                // Starts with no program remembered: the first htop is viewed, not fitted.
                TerminalFitMemory.reset()
            }
            session = TerminalSessionChoice.session(live: mac, mockDataEnabled: false, macName: "Mac", programName: "zsh")
        } else if TerminalDemoDriver.requestedPhases?.contains(where: { $0.hasPrefix("tuiheld-") }) == true {
            // `tuiheld`: the mock behind the phone's projection, as a Mac
            // terminal is, answering the full-screen app's size claim as the Mac does.
            let projecting = TerminalProjectingSession(inner: MockTerminalSession(playsIntro: false, macResize: .milliseconds(60)))
            projecting.holdsRows = !CommandLine.arguments.contains("-CmuxMobileTerminalDemoNoHeldRows")
            session = projecting
        } else {
            session = TerminalHostGridDemoSession.requestedSpec
                .flatMap(TerminalHostGridDemoSession.init(spec:)) ?? MockTerminalSession(macResize: Self.macResize)
        }
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "zsh — cmux-next")
        if let attach { model.demoFinalGrid = { attach.macState } }
        if let altMac {
            // The settle probe: htop is right at the PTY's grid, once no resize is on its way.
            model.demoFinalColumns = { altMac.resizeInFlight ? nil : altMac.ptyGrid.columns }
        }
        _model = State(initialValue: model)
        _host = State(initialValue: TerminalTabHost(model: model))
    }

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileTerminalDemo") }

    static var attachRequested: Bool { CommandLine.arguments.contains("-CmuxMobileTerminalDemoAttach") }

    /// `-CmuxMobileTerminalDemoMac`: the mock answers a resize as the Mac does
    /// (its grid, a mirror reset and a replay, a round trip later:
    /// `-CmuxMobileTerminalDemoMacMs`, default 60).
    private static var macResize: Duration? {
        guard CommandLine.arguments.contains("-CmuxMobileTerminalDemoMac") else { return nil }
        let ms = UserDefaults.standard.integer(forKey: "CmuxMobileTerminalDemoMacMs")
        return .milliseconds(ms > 0 ? ms : 60)
    }

    /// `-CmuxMobileTerminalDemoEmbedded`: the workspace tab page (TabsKit chrome
    /// insets, UIKit-presented Files and Links) instead of the standalone screen.
    private static let embedded = CommandLine.arguments.contains("-CmuxMobileTerminalDemoEmbedded")

    public var body: some View {
        Group {
            if Self.embedded {
                TerminalTabPage(host: host, insets: EdgeInsets(top: 62, leading: 0, bottom: 90, trailing: 0), isInteractive: true)
            } else {
                NavigationStack {
                    TerminalScreen(model: model)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // The driver's last step, for UI tests (`kbtui`).
            Text(model.demoNote)
                .font(.system(size: 2))
                .foregroundStyle(.clear)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.terminal-demo")
        }
        .task {
            // The attach demo: its trace goes in the step label once the
            // page's probe ended (5 s after the start), for UI tests.
            if Self.attachRequested {
                for _ in 0..<100 {
                    try? await ContinuousClock().sleep(for: .milliseconds(100))
                    guard let trace = model.controller?.attachTrace else { continue }
                    let ended = trace.marks.contains { $0.name == "probe-end" }
                    model.demoNote = "attach.\(ended ? "done" : "running") first=\(trace.firstRightMs ?? -1) "
                        + "fromstart=\(trace.firstRightFromStartMs ?? -1) marks=\(trace.line)"
                    if ended { return }
                }
                return
            }
            // The host grid demo is a still: no scripted phases. Its page's
            // layout goes in the step label, for UI tests.
            guard TerminalHostGridDemoSession.requestedSpec == nil else {
                for _ in 0..<20 {
                    try? await ContinuousClock().sleep(for: .milliseconds(250))
                    model.demoNote = "hostgrid " + (model.controller?.debugState ?? "-")
                }
                return
            }
            await TerminalDemoDriver(model: model).run(phases: TerminalDemoDriver.requestedPhases)
        }
    }
}

@MainActor
final class TerminalDemoDriver {
    let model: TerminalModel
    private var stepLog: [String] = []
    private var stepResizes = 0

    init(model: TerminalModel) { self.model = model }
    let clock = ContinuousClock()

    static var requestedPhases: [String]? {
        UserDefaults.standard.string(forKey: "CmuxMobileTerminalDemoPhases")?.split(separator: ",").map(String.init)
    }

    private func wait(_ seconds: Double) async {
        try? await clock.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func mark(_ label: String) {
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, label)
        print("[terminal-demo] \(line)", terminator: "")
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("terminal-demo-timeline.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func type(_ text: String) async {
        for character in text {
            model.composerText.append(character)
            await wait(0.06)
        }
    }

    private func joystick(_ dx: CGFloat, _ dy: CGFloat, seconds: Double) async {
        let steps = 8
        for step in 1...steps {
            model.joystickEngine.update(CGSize(width: dx * CGFloat(step) / CGFloat(steps), height: dy * CGFloat(step) / CGFloat(steps)))
            await wait(0.02)
        }
        await wait(seconds)
    }

    func run(phases: [String]?) async {
        let all = ["scroll", "keyboard", "tui", "vim", "attachments", "artifacts", "follow", "kbcodex", "rowprobe"]
        let selected = phases ?? all
        mark("start")
        for _ in 0..<10 {
            await wait(1)
            mark("state " + (model.controller?.debugState ?? "-"))
        }
        // Only when named: "oneattachment" leaves one picked photo and a draft, unsent.
        let named = ["oneattachment"]
        for phase in all + named where selected.contains(phase) {
            mark("phase \(phase)")
            switch phase {
            case "scroll": await scroll()
            case "keyboard": await keyboard()
            case "tui": await tui()
            case "vim": await vim()
            case "attachments": await attachments()
            case "oneattachment": await oneAttachment()
            case "artifacts": await artifacts()
            case "follow": await follow()
            case "kbcodex": await keyboardOverCodex()
            case "rowprobe": await rowProbe()
            default: break
            }
            await wait(1)
            mark("state " + (model.controller?.debugState ?? "-"))
        }
        // Opt-in only (not in `all`): the keyboard reversed mid-animation.
        if selected.contains("kbinterrupt") { await keyboardInterrupt() }
        if selected.contains("kbtui") { await keyboardOverTUI() }
        if selected.contains("kbclaude") { await keyboardOverTUI(command: "claude") }
        if selected.contains("kbshell") { await keyboardOverShell() }
        if selected.contains("tuihold") { await holdTUI() }
        if selected.contains("projection") { await projection() }
        if selected.contains("scrollbench") { await scrollBench() }
        if selected.contains("historyfling") { await historyFling() }
        if selected.contains("wide") { await wide() }
        for variant in ["primary", "mouse", "keys", "primary-load", "mouse-load", "keys-load", "primary-slow", "mouse-slow"]
        where selected.contains("tuipan-\(variant)") { await tuiPan(variant) }
        if selected.contains("altproj") { await alternateProjection() }
        for variant in ["keys", "keys-load"] where selected.contains("tuiheld-\(variant)") { await tuiHeld(variant) }
        for variant in ["find", "select"] where selected.contains("highlight-\(variant)") { await highlightScroll(variant) }
        mark("end")
        if let log = model.controller?.presentLog, !log.isEmpty,
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? log.joined(separator: "\n").write(to: documents.appendingPathComponent("present-log.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// `wide` (TerminalWideOutputUITests): a table 180 columns wide on a
    /// phone that fits about 50, then the page's sideways state every 250 ms
    /// for the UI test to read while it turns on Wide and pans: the mirror's
    /// columns, the phone's, the pan and the last column on screen.
    private func wide() async {
        model.composerText = "widetable 180 12"
        model.send()
        await wait(2)
        // `-CmuxMobileTerminalDemoWideView`: the page menu's Wide View, for the gallery.
        if CommandLine.arguments.contains("-CmuxMobileTerminalDemoWideView") {
            model.openWideView()
            await wait(1)
        }
        mark("wide ready " + (model.controller?.wideProbe ?? "-"))
        // `-CmuxMobileTerminalDemoWideType`: Wide on, then a 120-column paste
        // at the prompt: its echo carries the cursor far right of the page,
        // and the page pans after it (TerminalWideOutputUITests).
        if CommandLine.arguments.contains("-CmuxMobileTerminalDemoWideType") {
            model.setWide(true)
            await wait(2)
            model.controller?.surface.sendText(String(repeating: "x", count: 120), pressReturn: false)
            await wait(1.5)
            mark("wide typed " + (model.controller?.wideProbe ?? "-"))
        }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            model.demoNote = "wide ready " + (model.controller?.wideProbe ?? "-")
            await wait(0.25)
        }
    }

    /// D1: keyboard hide and show over Codex's short document, 10 times each.
    private func keyboardOverCodex() async {
        // Taller than the rows above the keyboard, shorter than the page (D1).
        model.composerText = "codex " + (UserDefaults.standard.string(forKey: "CmuxMobileDemoCodexRows") ?? "14")
        model.send()
        await wait(2)
        for index in 1...10 {
            mark("kb show \(index)")
            model.toggleKeyboard()
            await wait(1.8)
            mark("state " + (model.controller?.debugState ?? "-"))
            mark("kb hide \(index)")
            model.toggleKeyboard()
            await wait(1.8)
            mark("state " + (model.controller?.debugState ?? "-"))
        }
    }

    /// Round 8: which numbering each Ghostty point tag reads, over a short
    /// screen, scrollback, `clear` and more scrollback.
    private func rowProbe() async {
        func probe(_ label: String) {
            mark("probe \(label) " + (model.controller?.debugRowProbe ?? "-"))
        }
        probe("intro")
        for (label, command, seconds) in [("stream600", "stream 600 0", 6.0), ("clear", "clear", 20.0), ("stream30", "stream 30 0", 2.0),
                                          ("clear2", "clear", 2.0), ("stream3000", "stream 3000 0", 20.0)] {
            model.composerText = command
            model.send()
            await wait(seconds)
            probe(label)
            mark("state " + (model.controller?.debugState ?? "-"))
        }
    }

    /// Follows a 30 s numbered stream with no touch (termqa D7: one-frame jumps).
    private func follow() async {
        model.composerText = "stream 3000 8"
        model.send()
        await wait(32)
    }

    private func scroll() async {
        mark("fling up 7000")
        model.controller?.fling(velocity: -7000)
        await wait(3)
        mark("fling up 3500")
        model.controller?.fling(velocity: -3500)
        await wait(2.5)
        mark("fling down 9000")
        model.controller?.fling(velocity: 9000)
        await wait(3)
        mark("scroll to bottom")
        model.scrollToBottom()
        await wait(1.5)
    }

    /// Leo, 2026-11-21: "terminals are indeed fast now... but only the bare
    /// ones. this claude code cli is often slow to scroll up and down". The
    /// same flings over a bare shell's scrollback, then while the mock's
    /// inline Claude Code screen redraws (`claudeinline`), then with its
    /// clear-and-reprint as well. Each case marks the fling frames'
    /// intervals: `bench CASE frames=N p50=.. p95=.. max=.. hitches=..`.
    private func scrollBench() async {
        let cases: [(name: String, command: String?)] = [
            ("bare", nil),
            ("claude-inline", "claudeinline 50"),
            ("claude-inline-reprint", "claudeinline 50 20"),
            // A long session: 3,000 transcript rows, all reprinted every 2 s.
            ("claude-inline-long", "claudeinline 50 40 3000"),
            // Full screen: the drag is the wheel (T-SCROLL-12), not the page.
            ("claude-full", "claudewheel 50"),
            // Leo, 2026-11-24: "we can just treat the scroll like any pedestrian
            // scroll". The same app's history the phone keeps, scrolled as a
            // plain scroll view (TerminalTUIReader): no wheel, no round trip.
            ("claude-reader", "claudewheel 50"),
        ]
        model.composerText = "stream 600 1"
        model.send()
        await wait(4)
        var results: [String] = []
        for (name, command) in cases {
            if let command {
                model.composerText = command
                model.send()
                await wait(3)
            }
            let reader = name == "claude-reader"
            let full = name == "claude-full"
            if !full, !reader { model.scrollToBottom() }
            await wait(1)
            if reader {
                // Rows for the phone to keep: the app scrolls its transcript
                // up and back (every frame it draws on the way is kept).
                model.controller?.tuiFling(velocity: 3000)
                await wait(1.6)
                model.controller?.tuiFling(velocity: -3000)
                await wait(1.6)
            }
            let mock = model.session as? MockTerminalSession
            let reports = mock?.wheelReports ?? 0, rows = mock?.wheelRows ?? 0
            let sampler = FrameSampler()
            sampler.start()
            for _ in 0..<3 {
                if reader {
                    model.controller?.tuiReaderFling(velocity: 3000)
                    await wait(1.6)
                    model.controller?.tuiReaderFling(velocity: -3000)
                } else if full {
                    model.controller?.tuiFling(velocity: 3000)
                    await wait(1.6)
                    model.controller?.tuiFling(velocity: -3000)
                } else {
                    model.controller?.fling(velocity: -5000)
                    await wait(1.6)
                    model.controller?.fling(velocity: 5000)
                }
                await wait(1.6)
            }
            var line = "bench \(name) " + sampler.stop()
            if reader {
                let pacing = TerminalTUIReader.pacing
                line += " kept=\(mock?.tuiTranscriptRowsAbove ?? 0) reader=\(model.controller?.tuiReader.isOpen == true ? "open" : "closed") readerframes=\(pacing.frames) readerhitches=\(pacing.hitches) readerlongest=\(String(format: "%.1f", pacing.longestMs))"
            }
            if full, let mock {
                line += " wheel=\(mock.wheelReports - reports) wheelrows=\(mock.wheelRows - rows)"
            }
            mark(line)
            results.append(line)
            model.demoNote = results.joined(separator: " | ")
            if command != nil {
                model.sendControl("c")
                await wait(1)
            }
        }
        model.scrollToBottom()
        model.demoNote = "scrollbench done | " + results.joined(separator: " | ")
        mark(model.demoNote)
    }

    /// Leo, 2026-11-21: "this claude code cli is often slow to scroll up and
    /// down from ios". A Mac terminal attaches with its latest rows first; a
    /// reader's first fling up slows into the top of them and asks for the
    /// older rows, which come back as a reset and a replay of the whole
    /// window. The fling runs to its end and the older rows come after it:
    /// `historyfling done stopped=N fetches=N top=ROW`.
    private func historyFling() async {
        model.composerText = "historywindow 150 2000 60"
        model.send()
        await wait(3)
        model.scrollToBottom()
        await wait(1.5)
        let before = model.controller?.flingsStoppedByReset ?? 0
        mark("fling up into the top of the rows held")
        model.controller?.flingToNearTop()
        await wait(6)
        let stopped = (model.controller?.flingsStoppedByReset ?? 0) - before
        let fetches = (model.session as? MockTerminalSession)?.historyFetches ?? 0
        model.demoNote = "historyfling done stopped=\(stopped) fetches=\(fetches) state=\(model.controller?.debugState ?? "-")"
        mark(model.demoNote)
    }

    /// Leo, 2026-11-22: "if the data was sent through... why cant you simply
    /// scroll through the depiction that was already given?" A mock Claude
    /// Code: `primary` on the primary screen (its transcript in the
    /// scrollback, its live region redrawn every 80 ms), `mouse` in its
    /// full-screen mode on the alternate screen with the mouse asked for,
    /// `keys` the same without the mouse (Ghostty's alternate scroll sends
    /// cursor keys). The UI test pans with one finger for 10 s; this
    /// measures while a finger is down (and 0.6 s after, for a fling):
    /// `tuipan-VARIANT done frames=N p50=MS p95=MS max=MS hitches=N stalls=N
    /// sendFrames=N maxSendsPerFrame=N bytes=N sends=N appScrolls=N fetches=N
    /// touches=N` (`bytes`, `sends`: what the phone sent the "Mac", batched
    /// per main-queue turn as `DaemonTerminalSession` does; `appScrolls`:
    /// wheel reports and cursor keys the app took).
    ///
    /// `-load` (Leo, 2026-11-22: "testing under duress"): a long session of
    /// 12,000 styled rows, and output streaming the whole time the finger
    /// pans: `primary-load` redraws its live region every 16 ms, the
    /// full-screen app adds a row and redraws its whole screen every 16 ms.
    private func tuiPan(_ variant: String) async {
        // `-slow`: the UI test drags slowly, as a reader does (the demo runs the same).
        let base = variant.hasSuffix("-slow") ? String(variant.dropLast(5)) : variant
        let load = base.hasSuffix("-load")
        let screen = load ? String(base.dropLast(5)) : base
        (model.session as? MockTerminalSession)?.stampsRedraws = true
        model.composerText = screen == "primary"
            ? (load ? "claudecli 12000 16" : "claudecli 1500 80")
            : (load ? "claudefull 12000 \(screen) stream=16" : "claudefull 1500 \(screen)")
        model.send()
        await wait(load ? 6 : 3)
        guard let controller = model.controller, let window = controller.view.window,
              let session = model.session as? MockTerminalSession else {
            model.demoNote = "tuipan-\(variant) done error=nocontroller"
            return
        }
        session.batchesInputPerTurn = true
        defer { session.batchesInputPerTurn = false }
        let meter = TerminalPanMeter(window: window, sends: { [weak session] in session?.sends ?? 0 },
                                     position: { [weak controller] in controller?.debugContentY })
        let bytes = session.bytesFromPhone, fetches = session.historyFetches, sends = session.sends
        let scrolls = session.appScrolls
        session.paintSamples = []
        mark("tuipan-\(variant) ready isTUI=\(model.isTUI)")
        model.demoNote = "tuipan-\(variant) ready isTUI=\(model.isTUI)"
        // Until the pans are over: 4 s with no finger after the first (the
        // UI test's next drag can wait seconds for the app to idle), within 45 s.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            await wait(0.25)
            if let lastUp = meter.lastTouchUp, meter.touchesDown == 0, CACurrentMediaTime() - lastUp > 4 { break }
        }
        meter.stop()
        let result = meter.summary + meter.smoothness(rowHeight: controller.debugRowHeight) + " bytes=\(session.bytesFromPhone - bytes) sends=\(session.sends - sends)"
            + " appScrolls=\(session.appScrolls - scrolls) fetches=\(session.historyFetches - fetches) touches=\(meter.touches) isTUI=\(model.isTUI)"
            + Self.paintNote(session.paintSamples)
        model.demoNote = "tuipan-\(variant) done " + result
        mark(model.demoNote)
    }

    /// Leo, 2026-11-23: "if the data was sent through... why cant you simply
    /// scroll through the depiction that was already given?" `tuiheld-keys`:
    /// a mock full-screen app (no mouse) whose transcript scrolls off its
    /// region's top, behind ``TerminalProjectingSession``: a pan within the
    /// rows it scrolled off is painted on the phone and sends nothing.
    /// `-load`: 12,000 rows and a new row every 16 ms while the finger pans;
    /// the reader stays on the rows they read (`back`, rows back at the end).
    /// `-CmuxMobileTerminalDemoNoHeldRows`: every pan goes to the app, as
    /// before held rows (the "before" of the same harness).
    /// `tuiheld-VARIANT done ... back=N backSamples=N bytes=N sends=N appScrolls=N heldPaints=N
    /// held=N heldBytes=N paint... gesture=N gestureP50=MS gestureP95=MS`
    /// (`paint`: receive to paint of the app's writes; `gesture`: a pan's
    /// wheel to the present that showed its rows, held or the app's redraw).
    private func tuiHeld(_ variant: String) async {
        let load = variant.hasSuffix("-load")
        model.composerText = load ? "claudefull 12000 keys scroll stream=16" : "claudefull 1500 keys scroll"
        guard let projecting = model.session as? TerminalProjectingSession,
              let session = projecting.inner as? MockTerminalSession else {
            model.demoNote = "tuiheld-\(variant) done error=nosession"
            return
        }
        session.stampsRedraws = true
        projecting.stampsPans = true
        let reports = PaintReports()
        projecting.onPaintReport = { samples in
            for sample in samples {
                if (sample.first ?? 0) < 0 { reports.gesture.append(sample) } else { reports.receive.append(sample) }
            }
        }
        model.send()
        // Up once the app's screen holds rows (the size claim's answer and replay come first).
        let up = Date().addingTimeInterval(load ? 20 : 12)
        while Date() < up, !(model.isTUI && projecting.heldRows.rows > 0) { await wait(0.25) }
        await wait(1)
        guard let controller = model.controller, let window = controller.view.window else {
            model.demoNote = "tuiheld-\(variant) done error=nocontroller"
            return
        }
        session.batchesInputPerTurn = true
        defer { session.batchesInputPerTurn = false }
        let meter = TerminalPanMeter(window: window, sends: { [weak session] in session?.sends ?? 0 })
        let bytes = session.bytesFromPhone, sends = session.sends, scrolls = session.appScrolls
        let paints = projecting.heldPaints
        reports.receive = []
        reports.gesture = []
        let ready = "tuiheld-\(variant) ready isTUI=\(model.isTUI) held=\(projecting.heldRows.rows) holds=\(projecting.holdsRows)"
        mark(ready)
        model.demoNote = ready
        let deadline = Date().addingTimeInterval(45)
        var backSamples = 0
        while Date() < deadline {
            await wait(0.25)
            if projecting.heldRowsBack > 0 { backSamples += 1 }
            if let lastUp = meter.lastTouchUp, meter.touchesDown == 0, CACurrentMediaTime() - lastUp > 4 { break }
        }
        meter.stop()
        // The last report: the screen reports every 5 s (the spinner keeps presenting).
        await wait(5.5)
        let held = projecting.heldRows
        // Where the reader is after the finger lifted and (`-load`) the app
        // kept writing for 9 s: output never takes them back to live.
        let result = meter.summary + " back=\(projecting.heldRowsBack) backSamples=\(backSamples)"
            + " bytes=\(session.bytesFromPhone - bytes) sends=\(session.sends - sends)"
            + " appScrolls=\(session.appScrolls - scrolls) heldPaints=\(projecting.heldPaints - paints)"
            + " held=\(held.rows) heldBytes=\(held.bytes) touches=\(meter.touches) isTUI=\(model.isTUI)"
            + Self.paintNote(reports.receive) + Self.paintNote(reports.gesture, name: "gesture")
        model.demoNote = "tuiheld-\(variant) done " + result
        mark(model.demoNote)
    }

    /// `tuiheld`'s paint reports: the app's writes, and the pans (negative seq).
    @MainActor private final class PaintReports {
        var receive: [TerminalPaintTally.Sample] = []
        var gesture: [TerminalPaintTally.Sample] = []
    }

    /// Leo, 2026-11-24: "sometimes the highlights in terminal just float and dont move when i
    /// scroll?" A mock Claude Code in its full-screen mode with a highlight up while its screen
    /// scrolls: `find` searches "lorem" and the UI test's finger scrolls the app; `select`
    /// selects "transcript row N" on a row and the app's streamed reply scrolls it.
    /// `highlight-VARIANT ready ...`, then `highlight-VARIANT done appScrolls=N` with
    /// `on=N off=N missed=N` (find) or `sel=on|off|none` (select): `off` is a highlight left
    /// over other text (``TerminalViewController/findHighlightProbe(query:)``).
    private func highlightScroll(_ variant: String) async {
        let find = variant == "find"
        model.composerText = find ? "claudefull 1500 mouse" : "claudefull 1500 mouse stream=400"
        model.send()
        await wait(3)
        guard let controller = model.controller, let window = controller.view.window,
              let session = model.session as? MockTerminalSession else {
            model.demoNote = "highlight-\(variant) done error=nocontroller"
            return
        }
        let scrolls = session.appScrolls
        if find {
            controller.finder.debugSearch("lorem")
            await wait(1.5)
            let before = controller.findHighlightProbe(query: "lorem")
            model.demoNote = "highlight-find ready isTUI=\(model.isTUI) \(before)"
            mark(model.demoNote)
            // Until the finger's scrolls are over: 2.5 s with no finger after the first, within 45 s.
            let meter = TerminalPanMeter(window: window, sends: { [weak session] in session?.sends ?? 0 })
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                await wait(0.25)
                if let lastUp = meter.lastTouchUp, meter.touchesDown == 0, CACurrentMediaTime() - lastUp > 2.5 { break }
            }
            meter.stop()
            model.demoNote = "highlight-find done appScrolls=\(session.appScrolls - scrolls) "
                + controller.findHighlightProbe(query: "lorem")
        } else {
            // A "transcript row N" row ten rows above the input box: it stays on the screen
            // while the reply streams a row every 400 ms.
            let rows = controller.surface.grid.rows
            let row = (1..<max(1, rows - 12)).reversed().first {
                controller.tuiSelection.rowText($0)?.hasPrefix("  transcript row ") == true
            }
            guard let row, let line = controller.tuiSelection.rowText(row),
                  let number = line.dropFirst(17).split(separator: " ").first else {
                model.demoNote = "highlight-select done error=norow"
                return
            }
            let label = "transcript row \(number)"
            let text = controller.selectTUIForProbe(row: row, columns: 2...(1 + label.count)) ?? ""
            model.demoNote = "highlight-select ready isTUI=\(model.isTUI) row=\(row) text=\(text.replacingOccurrences(of: " ", with: "_"))"
            mark(model.demoNote)
            await wait(3)
            model.demoNote = "highlight-select done appScrolls=\(session.appScrolls - scrolls) " + controller.selectionHighlightProbe(text: label)
        }
        mark(model.demoNote)
    }

    /// ` paint=N paintP50=MS paintP95=MS`: the screen's receive to the present that showed it
    /// (``TerminalPaintTally``), over the stamped writes it reported.
    static func paintNote(_ samples: [TerminalPaintTally.Sample], name: String = "paint") -> String {
        guard let paint = TerminalPaintTally.receiveToPaint(samples) else { return " \(name)=0" }
        return String(format: " %@=%d %@P50=%.1f %@P95=%.1f", name, samples.count, name, paint.p50, name, paint.p95)
    }

    private func keyboard() async {
        mark("keyboard show (composer)")
        model.toggleKeyboard()
        await wait(1.8)
        mark("state " + (model.controller?.debugState ?? "-"))
        mark("type")
        await type("echo hello from the composer")
        await wait(0.6)
        mark("send")
        model.send()
        await wait(1.2)
        mark("send empty (Enter)")
        model.send()
        await wait(1.2)
        mark("keyboard hide")
        model.toggleKeyboard()
        await wait(1.8)
        mark("keyboard show")
        model.toggleKeyboard()
        await wait(1.8)
        mark("keyboard hide")
        model.toggleKeyboard()
        await wait(1.5)
    }

    /// `kbinterrupt`: the keyboard key and then the terminal 0.1 s apart (the
    /// keyboard is still moving), the same calls a tap on each makes; then the
    /// keyboard key twice 0.1 s apart. Each second action reverses the first
    /// from where the keyboard is, never after it settles.
    /// `tuihold` (opt-in): vim, left running with the keyboard down for a UI
    /// test to drive (KeyboardMotionBenchUITests). `demoNote` reads
    /// `tui.ready` once it is up, `done.notui` when it never became full screen.
    private func holdTUI() async {
        model.controller?.surface.sendText("vim README.md", pressReturn: true)
        await wait(2.5)
        note(model.isTUI ? "tui.ready" : "done.notui")
    }

    /// `kbtui` (opt-in): vim, then the keyboard key pressed to show and hide
    /// the keyboard five times. `demoNote` (the `debug.terminal-demo` label) ends
    /// at `done.rz<before>-<after>`: the PTY resizes sent before and after.
    /// `-CmuxMobileTerminalDemoTUI htop` runs htop (it reports the mouse)
    /// instead of vim.
    /// `kbclaude` (opt-in): the same with the mock Claude Code screen (its
    /// header box on the first rows, the cursor in its input box at the
    /// bottom), whose header stays pinned above the keyboard.
    private func keyboardOverTUI(command: String? = nil) async {
        let program = command ?? (UserDefaults.standard.string(forKey: "CmuxMobileTerminalDemoTUI") == "htop" ? "htop" : "vim README.md")
        model.controller?.surface.sendText(program, pressReturn: true)
        // Past the resize settle (250 ms), so every size before the toggles is counted.
        await wait(2.5)
        guard model.isTUI else {
            note("done.notui")
            return
        }
        let before = model.ptyResizesSent
        note("tui.rz\(before)")
        // Keyboard down, vim settled: the UI test's first screenshot. Each
        // step outlasts the keyboard's animation, the 250 ms resize settle and
        // the UI test's screenshot on a slow simulator host: a toggle before
        // the last one settled reverses it and sends no resize.
        await wait(2.5)
        // `-CmuxMobileTerminalDemoToggle` picks how the keyboard moves:
        // `key` (the keyboard key, the default), `tap` (a tap on the
        // terminal shows it; the key hides it), `system` (shown by the key,
        // hidden from outside our code: the terminal resigns, as a swipe or
        // the system does, so only will-hide claims the rows), `reverse`
        // (shown, then hidden 80 ms later, before the Mac answers),
        // `double` (shown, hidden and shown again 100 ms apart) and `send`
        // (the composer shows it, a message is sent from it, the key hides it).
        let mode = UserDefaults.standard.string(forKey: "CmuxMobileTerminalDemoToggle") ?? "key"
        for round in 0..<5 {
            switch mode {
            case "tap":
                note("show\(round)")
                model.controller?.debugTapTerminal()
                await wait(2.5)
                note("hide\(round)")
                model.toggleKeyboard()
            case "send":
                // Leo's flow (ask-b8451d6e4b): the composer takes the keyboard,
                // a message goes from it to the app, and the keyboard key
                // then puts the keyboard away.
                note("show\(round)")
                model.focusComposer()
                await wait(1.5)
                await type("jj")
                model.send()
                await wait(0.6)
                note("hide\(round)")
                model.toggleKeyboard()
            case "system":
                note("show\(round)")
                model.toggleKeyboard()
                await wait(2.5)
                note("hide\(round)")
                _ = model.controller?.surface.resignFirstResponder()
            case "reverse":
                note("show\(round)")
                model.toggleKeyboard()
                await wait(0.08)
                note("hide\(round)")
                model.toggleKeyboard()
            case "double":
                note("show\(round)")
                model.toggleKeyboard()
                await wait(0.1)
                model.toggleKeyboard()
                await wait(0.1)
                model.toggleKeyboard()
                await wait(2.5)
                note("hide\(round)")
                model.toggleKeyboard()
            default:
                note("show\(round)")
                model.toggleKeyboard()
                await wait(2.5)
                note("hide\(round)")
                model.toggleKeyboard()
            }
            await wait(2.5)
        }
        await wait(0.5)
        note("done.rz\(before)-\(model.ptyResizesSent)")
    }

    /// `kbshell` (opt-in): the primary screen, then the keyboard key pressed
    /// to show and hide the keyboard five times. A shell never resizes for
    /// the keyboard (R1-1); `demoNote` ends at `done.rz<before>-<after>`.
    /// `-CmuxMobileTerminalDemoShell` picks what the screen shows:
    /// `prompt` (the default), `follow` (a long build log, at its end),
    /// `reading` (the same log, scrolled up), `stream` (numbered rows
    /// streaming through the toggles) or `inline` (an inline agent's box on
    /// the primary screen, like Codex CLI).
    private func keyboardOverShell() async {
        let scenario = UserDefaults.standard.string(forKey: "CmuxMobileTerminalDemoShell") ?? "prompt"
        switch scenario {
        case "follow", "reading":
            model.composerText = "cargo build"
            model.send()
            await wait(6)
            if scenario == "reading" {
                model.controller?.fling(velocity: -3500)
                await wait(2.5)
            }
        case "stream":
            model.composerText = "stream 3000 30"
            model.send()
            await wait(1.5)
        case "inline":
            model.composerText = "codex 14"
            model.send()
            await wait(2)
        default:
            await wait(1)
        }
        let before = model.ptyResizesSent
        note("shell.rz\(before)")
        await wait(1.6)
        for round in 0..<5 {
            note("show\(round)")
            model.toggleKeyboard()
            await wait(2.5)
            note("hide\(round)")
            model.toggleKeyboard()
            await wait(2.5)
        }
        await wait(0.5)
        note("done.rz\(before)-\(model.ptyResizesSent)")
    }

    /// `projection` (opt-in): a shell on a Mac pane of 120x40
    /// (`MacPaneMockSession`). The keyboard is shown and hidden; then the
    /// UI test switches apps and rotates the phone while `demoNote` keeps
    /// `p.<stage>.mac<PTY resizes>.wide<wide grids>.rs<mirror resets>`
    /// current (TerminalProjectionUITests).
    private func projection() async {
        let mac = model.session.underlyingSession as? MacPaneMockSession
        func counters(_ stage: String) {
            note("p.\(stage).mac\(mac?.ptyResizes ?? -1).wide\(model.wideGridsShown).rs\(model.mirrorResets).ret\(model.lastReturnMs)"
                + ".nar\(model.narrowKeyboardFrames).kbb\(model.keyboardBounces)")
        }
        counters("attach")
        await wait(1)
        counters("kbstart")
        model.toggleKeyboard()
        await wait(1.6)
        counters("kbup")
        await wait(1)
        model.toggleKeyboard()
        await wait(1.6)
        counters("kb")
        await wait(0.5)
        for _ in 0..<600 {
            counters("live")
            await wait(0.25)
        }
    }

    /// `altproj` (opt-in): htop on a Mac pane of 120x40 that answers a claim
    /// a round trip later (`MacPaneMockSession`). `demoNote` keeps
    /// `a.<stage>.mac<PTY resizes>.cl<claims and releases>.rb<replay bytes>
    /// .st<settle ms>.uf<frames at a grid not final>.zg<zoom gestures>
    /// .zs<zoom %>.cols<columns drawn>` current (TerminalProjectionUITests
    /// `testAlternateScreen…`). Stages: `attach` (settled), `gestures` (the
    /// UI test rotates, pinches and double taps until three zoom gestures
    /// land, or 75 s), `kbup` and `kb` (the keyboard shown and hidden),
    /// `typed` (`abc` typed into htop), `quit` (`q`), `again` (htop started
    /// again from the shell), then `done`. A Mac that keeps its size
    /// (`testAMacThatKeepsItsSize…`) skips the gestures stage: its test
    /// drives none.
    private func alternateProjection() async {
        let mac = model.session.underlyingSession as? MacPaneMockSession
        func counters(_ stage: String) {
            let columns = model.controller?.appliedHostColumns ?? -1
            note("a.\(stage).mac\(mac?.ptyResizes ?? -1).cl\(mac?.claimChanges ?? -1).rb\(mac?.replayBytes ?? -1)"
                + ".st\(model.settleMs).uf\(model.unsettledTUIFrames).zg\(model.zoomGestures)"
                + ".zs\(Int((model.zoomScale * 100).rounded())).cols\(columns)")
        }
        func settle(_ stage: String, timeout: Double) async {
            var waited = 0.0
            while model.settleMs == -1, waited < timeout {
                counters(stage + "ing")
                await wait(0.1)
                waited += 0.1
            }
            await wait(0.3)
            counters(stage)
        }
        await settle("attach", timeout: 8)
        await wait(1)
        var waited = 0.0
        while model.zoomGestures < 3, waited < (mac?.keepsSize == true ? 0 : 75) {
            counters("gestures")
            await wait(0.25)
            waited += 0.25
        }
        await wait(1)
        counters("gestured")
        await wait(0.5)
        model.toggleKeyboard()
        await wait(1.6)
        counters("kbup")
        await wait(0.6)
        model.toggleKeyboard()
        await wait(1.6)
        counters("kb")
        await wait(0.5)
        model.controller?.startSettleProbe()
        model.controller?.surface.sendText("abc", pressReturn: false, fullScreenApp: true)
        await settle("typed", timeout: 3)
        await wait(1)
        model.controller?.surface.sendText("q", pressReturn: false, fullScreenApp: true)
        await wait(1.5)
        counters("quit")
        await wait(0.5)
        model.controller?.startSettleProbe()
        model.controller?.surface.sendText("htop", pressReturn: true)
        await settle("again", timeout: 6)
        await wait(1)
        for _ in 0..<600 {
            counters("done")
            await wait(0.25)
        }
    }

    private func note(_ label: String) {
        mark(label)
        // Each toggle step's PTY resizes, kept as a cumulative log: a UI test
        // that misses a label (its probe reads the latest one) still reads
        // every step at the end (`done...steps=show0:1,hide0:1,...`).
        if let last = stepLog.last, last.hasSuffix(":") {
            stepLog[stepLog.count - 1] += "\(model.ptyResizesSent - stepResizes)"
        }
        if label.range(of: #"^(show|hide)\d+$"#, options: .regularExpression) != nil {
            stepLog.append(label + ":")
            stepResizes = model.ptyResizesSent
        }
        model.demoNote = label.hasPrefix("done.") ? label + ".steps=" + stepLog.joined(separator: ",") : label
    }

    private func keyboardInterrupt() async {
        model.controller?.focusTerminal()
        await wait(1.5)
        for round in 1...3 {
            mark("kbinterrupt hide \(round)")
            model.toggleKeyboard()
            await wait(0.1)
            mark("kbinterrupt terminal \(round)")
            model.controller?.focusTerminal()
            await wait(1.5)
        }
        model.toggleKeyboard()
        await wait(1.5)
        for round in 1...2 {
            mark("kbinterrupt show \(round)")
            model.toggleKeyboard()
            await wait(0.1)
            mark("kbinterrupt key \(round)")
            model.toggleKeyboard()
            await wait(1.5)
        }
    }

    private func tui() async {
        mark("run htop")
        model.controller?.surface.sendText("htop", pressReturn: true)
        await wait(2.5)
        mark("keyboard show (direct)")
        model.toggleKeyboard()
        await wait(2.2)
        mark("state " + (model.controller?.debugState ?? "-"))
        mark("keyboard hide")
        model.toggleKeyboard()
        await wait(2.2)
        mark("keyboard show")
        model.toggleKeyboard()
        await wait(2)
        mark("quit htop")
        model.controller?.surface.sendText("q", pressReturn: false)
        await wait(1.5)
        mark("keyboard hide")
        model.controller?.hideKeyboard()
        await wait(1.5)
    }

    private func vim() async {
        mark("run vim")
        model.controller?.surface.sendText("vim README.md", pressReturn: true)
        await wait(1.5)
        model.controller?.focusTerminal()
        await wait(1.5)
        mark("joystick gear 1 down")
        await joystick(0, 12, seconds: 1.2)
        mark("joystick gear 2 right")
        await joystick(20, 0, seconds: 1.0)
        mark("joystick gear 3 down")
        await joystick(0, 28, seconds: 0.5)
        mark("joystick gear 3 up")
        await joystick(0, -28, seconds: 0.4)
        model.joystickEngine.release()
        await wait(0.8)
        mark("key bar arrows + esc")
        model.keyBar(.down)
        await wait(0.3)
        model.keyBar(.right)
        await wait(0.3)
        model.keyBar(.escape)
        await wait(0.5)
        mark("sticky ctrl")
        model.keyBar(.control)
        await wait(0.8)
        model.keyBar(.control)
        model.keyBar(.control)
        await wait(0.8)
        model.keyBar(.control)
        await wait(0.5)
        mark(":q")
        model.controller?.surface.sendText(":q", pressReturn: true, fullScreenApp: model.isTUI)
        await wait(1.2)
        model.controller?.hideKeyboard()
        await wait(1.5)
    }

    /// The common case of one attachment, left in the composer with a draft:
    /// the photo sits where the text starts (the gallery's composer scenes).
    private func oneAttachment() async {
        mark("one attachment")
        let image = await MockArtifactSource.screenshotPNG().flatMap(UIImage.init(data:))
        model.addAttachment(ComposerAttachment(kind: .image, name: "terminal.png", thumbnail: image))
        await wait(0.6)
        model.focusComposer()
        await wait(1.2)
        await type("what's wrong here?")
        await wait(30)
    }

    private func attachments() async {
        mark("photo picker")
        model.showPhotoPicker = true
        await wait(3)
        model.showPhotoPicker = false
        await wait(1.2)
        mark("file importer")
        model.showFileImporter = true
        await wait(3)
        model.showFileImporter = false
        await wait(1.2)
        mark("attachments added")
        let image = await MockArtifactSource.screenshotPNG().flatMap(UIImage.init(data:))
        model.addAttachment(ComposerAttachment(kind: .image, name: "terminal.png", thumbnail: image))
        await wait(0.4)
        if let url = try? await MockArtifactSource.recordingURL() {
            model.addAttachment(ComposerAttachment(kind: .video, name: "demo.mp4", thumbnail: await TerminalComposer.videoThumbnail(url)))
        }
        await wait(0.4)
        model.addAttachment(ComposerAttachment(kind: .file, name: "build.log", byteCount: 48_213))
        await wait(1)
        model.focusComposer()
        await wait(1.2)
        await type("summarize these")
        await wait(0.8)
        mark("send with attachments")
        model.send()
        await wait(1.5)
        model.controller?.hideKeyboard()
        await wait(1.5)
    }

    private func artifacts() async {
        mark("artifacts sheet")
        model.showArtifacts = true
        await wait(2.5)
        for reference in ["index.html", "README.md", "screenshots/terminal.png", "src/link/mux.rs", "recordings/demo.mp4"] {
            guard let artifact = model.artifacts.first(where: { $0.reference == reference }) else { continue }
            mark("preview \(reference)")
            model.previewShowsSource = false
            model.artifactPath = [artifact]
            await wait(2.5)
            if artifact.kind == .html || artifact.kind == .markdown {
                mark("source \(reference)")
                model.previewShowsSource = true
                await wait(2)
            }
            model.artifactPath = []
            await wait(1)
        }
        model.showArtifacts = false
        await wait(1)
    }
}

/// DEBUG bench (`tuipan`): display frames while a finger is on the screen
/// (and 0.6 s after it lifts, for the fling). A frame interval over 1.5
/// display periods is a hitch, over 50 ms a main-thread stall. Touches are
/// watched by a recognizer on the window that never recognizes and never
/// delays or cancels a touch.
@MainActor
final class TerminalPanMeter: NSObject {
    private final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var changed: (Int, TimeInterval) -> Void = { _, _ in }
        private var down = 0

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            down += touches.count
            changed(down, CACurrentMediaTime())
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches) }

        private func lifted(_ touches: Set<UITouch>) {
            down = max(0, down - touches.count)
            changed(down, CACurrentMediaTime())
            if down == 0 { state = .failed }
        }

        override func reset() { down = 0 }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    private(set) var touchesDown = 0
    /// Fingers that landed while measuring.
    private(set) var touches = 0
    private(set) var lastTouchUp: CFTimeInterval?
    private var intervals: [Double] = []
    private var lastFrame: CFTimeInterval?
    private var period: Double = 1.0 / 60
    private var link: CADisplayLink?
    private let watcher = TouchWatcher(target: nil, action: nil)
    private weak var window: UIWindow?
    /// Sends to the "Mac" so far, read every frame.
    private let sends: () -> Int
    private var lastSends = 0
    /// Where the content was drawn (points), read every measured frame (``TerminalScrollSmoothness``).
    private let position: () -> CGFloat?
    private var lastPosition: CGFloat?
    /// How far it moved each measured frame (points).
    private var steps: [CGFloat] = []
    /// Measured frames that had a send, and the most sends in one frame.
    private var sendFrames = 0
    private var maxSendsPerFrame = 0

    init(window: UIWindow, sends: @escaping () -> Int = { 0 }, position: @escaping () -> CGFloat? = { nil }) {
        self.window = window
        self.sends = sends
        self.position = position
        lastSends = sends()
        super.init()
        watcher.changed = { [weak self] down, time in
            guard let self else { return }
            if down > touchesDown { touches += down - touchesDown }
            touchesDown = down
            if down == 0 { lastTouchUp = time }
        }
        window.addGestureRecognizer(watcher)
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = .terminal
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private var active: Bool {
        touchesDown > 0 || lastTouchUp.map { CACurrentMediaTime() - $0 < 0.6 } ?? false
    }

    @objc private func frame(_ link: CADisplayLink) {
        defer { lastFrame = link.timestamp }
        if link.duration > 0 { period = link.duration }
        let sent = sends()
        defer { lastSends = sent }
        let y = position()
        defer { lastPosition = y }
        guard active, let lastFrame else { return }
        intervals.append(link.timestamp - lastFrame)
        if let y, let lastPosition { steps.append(abs(y - lastPosition)) }
        if sent > lastSends { sendFrames += 1 }
        maxSendsPerFrame = max(maxSendsPerFrame, sent - lastSends)
    }

    func stop() {
        link?.invalidate()
        link = nil
        window?.removeGestureRecognizer(watcher)
    }

    var summary: String {
        let sorted = intervals.sorted()
        func ms(_ quantile: Double) -> String {
            guard !sorted.isEmpty else { return "-" }
            return String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * quantile))] * 1000)
        }
        let hitches = intervals.filter { $0 > period * 1.5 }.count
        let stalls = intervals.filter { $0 > 0.05 }.count
        return "frames=\(intervals.count) p50=\(ms(0.5)) p95=\(ms(0.95)) p99=\(ms(0.99)) max=\(ms(1)) hitches=\(hitches) stalls=\(stalls)"
            + " sendFrames=\(sendFrames) maxSendsPerFrame=\(maxSendsPerFrame) periodMs=\(String(format: "%.1f", period * 1000))"
    }
}

extension TerminalPanMeter {
    /// How smoothly the content moved while measured (`motionFrames=0` when it never moved).
    func smoothness(rowHeight: CGFloat) -> String {
        TerminalScrollSmoothness(steps: steps)?.note(rowHeight: rowHeight) ?? " motionFrames=0"
    }
}

/// Frame intervals from a display link at the screen's top rate, for
/// `scrollBench` (works without `-CmuxMobileFrameLog`).
@MainActor
private final class FrameSampler: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let top = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: top, maximum: top, preferred: top)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { intervals.append((link.timestamp - last) * 1000) }
        last = link.timestamp
    }

    /// Stops and returns `frames=N p50=.. p95=.. max=.. hitches=..` (ms).
    func stop() -> String {
        link?.invalidate()
        link = nil
        let sorted = intervals.sorted()
        guard !sorted.isEmpty else { return "frames=0" }
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let frame = 1000 / Double(max(60, UIScreen.main.maximumFramesPerSecond))
        let hitches = sorted.filter { $0 > frame * 1.5 }.count
        return String(format: "frames=%d p50=%.2f p95=%.2f max=%.2f hitches=%d", sorted.count, pct(0.5), pct(0.95), sorted.last ?? 0, hitches)
    }
}
#endif
