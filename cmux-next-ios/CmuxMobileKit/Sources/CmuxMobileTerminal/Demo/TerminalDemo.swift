#if os(iOS) && DEBUG
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
        let session: any TerminalSession = TerminalHostGridDemoSession.requestedSpec
            .flatMap(TerminalHostGridDemoSession.init(spec:)) ?? MockTerminalSession(macResize: Self.macResize)
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "zsh — cmux-next")
        _model = State(initialValue: model)
        _host = State(initialValue: TerminalTabHost(model: model))
    }

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileTerminalDemo") }

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
            // The host grid demo is a still: no scripted phases.
            guard TerminalHostGridDemoSession.requestedSpec == nil else { return }
            let phases = UserDefaults.standard.string(forKey: "CmuxMobileTerminalDemoPhases")?
                .split(separator: ",").map(String.init)
            await TerminalDemoDriver(model: model).run(phases: phases)
        }
    }
}

@MainActor
struct TerminalDemoDriver {
    let model: TerminalModel
    let clock = ContinuousClock()

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
        for phase in all where selected.contains(phase) {
            mark("phase \(phase)")
            switch phase {
            case "scroll": await scroll()
            case "keyboard": await keyboard()
            case "tui": await tui()
            case "vim": await vim()
            case "attachments": await attachments()
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
        if selected.contains("kbshell") { await keyboardOverShell() }
        mark("end")
        if let log = model.controller?.presentLog, !log.isEmpty,
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? log.joined(separator: "\n").write(to: documents.appendingPathComponent("present-log.txt"), atomically: true, encoding: .utf8)
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
    /// `kbtui` (opt-in): vim, then the keyboard key pressed to show and hide
    /// the keyboard five times. `demoNote` (the `debug.terminal-demo` label) ends
    /// at `done.rz<before>-<after>`: the PTY resizes sent before and after.
    /// `-CmuxMobileTerminalDemoTUI htop` runs htop (it reports the mouse)
    /// instead of vim.
    private func keyboardOverTUI() async {
        let program = UserDefaults.standard.string(forKey: "CmuxMobileTerminalDemoTUI") == "htop" ? "htop" : "vim README.md"
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

    private func note(_ label: String) {
        mark(label)
        model.demoNote = label
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
#endif
