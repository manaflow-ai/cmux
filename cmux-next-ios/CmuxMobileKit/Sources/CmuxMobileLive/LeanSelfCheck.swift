#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import OSLog
import UIKit

private let log = Logger(subsystem: "dev.cmux.mobile", category: "self-check")

/// The lean terminal self-check (Leo, 2026-11-17: "how's the lean terminal view on phone?
/// proven upholding behaviour yet? headers left right end of terminal lines etc?"): a hidden
/// debug action that only the Mac starts (`cmux device self-check`, over the link's
/// `self-check` service, ``LeanSelfCheckLink``), on any build of the app, a release one
/// included. Nothing in it reads a host path: the sessions ship in the app bundle (the agent
/// CLI bench sessions, cmux-agent-cli-render `tests/parity.rs`, project.yml).
///
/// Each case is one session at one daemon frame, the same cases as the simulator pixel matrix
/// (`AgentCLIHybridPixelMatrixUITests`). The app's own terminal screen draws it twice on one
/// stage in the same frames (``TerminalSelfCheckStage``): from the PTY's bytes and from lean
/// frames (`agent-cli-lean`), each through the app's own `DaemonTerminalSession` and a fake Mac
/// (``HybridBenchDaemon``). The two presented frames are compared pixel for pixel
/// (``LeanSelfCheckDiff``) and the counts, the grids' and cursors' places and the three images
/// go to the Mac, which judges them. The person's setting for lean frames is never read or
/// changed: each side has its own (``SelfCheckDefaults``).
@MainActor
final class LeanSelfCheck {
    /// One case: `session` at the daemon frame of `atMs`.
    struct Case {
        enum Step {
            case none
            /// The stage takes the phone's other orientation's size (the screens lay out again).
            case landscape
            /// The screens leave the window and come back (Ghostty stops and starts drawing, as
            /// when the app goes to the background and comes back).
            case background
        }

        let row: Int
        let session: String
        let label: String
        let atMs: Int
        var panEnd = false
        var sameLayout = false
        var step = Step.none

        var id: String { "row\(row)-\(session)-\(label.isEmpty ? "" : label + "-")\(atMs)ms\(panEnd ? "-end" : "")" }
    }

    static let agents = ["claude-code-2.1.310", "codex-0.164.0", "opencode-1.19.5"]
    private var sessions: [String: BenchSession] = [:]

    func session(_ name: String) throws -> BenchSession {
        if let session = sessions[name] { return session }
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw SelfCheckError("the app bundle has no \(name).json")
        }
        guard let session = BenchSession(try Data(contentsOf: url)) else { throw SelfCheckError("\(name).json is not a session") }
        sessions[name] = session
        return session
    }

    /// Three daemon frames after the attach: a quarter in, halfway, the last.
    func stills(_ name: String) throws -> [Int] {
        let frames = try session(name).leanFrames.map(\.atMs)
        guard frames.count > 8, let last = frames.last else { throw SelfCheckError("\(name): too few frames") }
        return [frames[frames.count / 4], frames[frames.count / 2], last]
    }

    /// The last daemon frame at or before the session's `moment`.
    func still(_ name: String, _ moment: String) throws -> Int {
        let session = try session(name)
        guard let at = session.moments.first(where: { $0.name == moment })?.atMs else { throw SelfCheckError("\(name): no \(moment)") }
        guard let frame = session.leanFrames.map(\.atMs).last(where: { $0 <= at }) else {
            throw SelfCheckError("\(name) \(moment): no frame before it")
        }
        return frame
    }

    /// The cases of `row` (1 to 9), as the simulator pixel matrix runs them.
    func cases(row: Int) throws -> [Case] {
        let matrix = "pixel-matrix", bash = "shell-bash-5.2"
        switch row {
        case 1:
            return try Self.agents.flatMap { name in try stills(name).map { Case(row: 1, session: name, label: "", atMs: $0) } }
        case 2:
            let edges = try still(matrix, "edges")
            return [Case(row: 2, session: matrix, label: "edges", atMs: edges),
                    Case(row: 2, session: matrix, label: "edges", atMs: edges, panEnd: true)]
                + (try Self.agents.map { Case(row: 2, session: $0, label: "last", atMs: try stills($0)[2], panEnd: true) })
        case 3:
            let wrapped = try still(matrix, "wrapped")
            return [Case(row: 3, session: matrix, label: "wrapped", atMs: wrapped),
                    Case(row: 3, session: matrix, label: "wrapped", atMs: wrapped, panEnd: true),
                    Case(row: 3, session: bash, label: "wrapped", atMs: try still(bash, "wrapped"))]
        case 4:
            let wide = try still(matrix, "wide")
            return [Case(row: 4, session: matrix, label: "wide", atMs: wide),
                    Case(row: 4, session: matrix, label: "wide", atMs: wide, panEnd: true),
                    Case(row: 4, session: bash, label: "unicode", atMs: try still(bash, "unicode"))]
        case 5:
            let box = try still(matrix, "box")
            return [Case(row: 5, session: matrix, label: "box", atMs: box),
                    Case(row: 5, session: matrix, label: "box", atMs: box, panEnd: true)]
        case 6:
            return [Case(row: 6, session: matrix, label: "alt-in", atMs: try still(matrix, "box"), sameLayout: true),
                    Case(row: 6, session: matrix, label: "alt-out", atMs: try still(matrix, "left_alt"), sameLayout: true),
                    Case(row: 6, session: bash, label: "alt-in", atMs: try still(bash, "alt"), sameLayout: true),
                    Case(row: 6, session: bash, label: "alt-out", atMs: try still(bash, "before_drop"), sameLayout: true)]
        case 7:
            return [Case(row: 7, session: matrix, label: "cursor-mid", atMs: try still(matrix, "cursor_mid")),
                    Case(row: 7, session: matrix, label: "cursor-edge", atMs: try still(matrix, "cursor_edge"), panEnd: true),
                    Case(row: 7, session: matrix, label: "cursor-prompt", atMs: try still(matrix, "done")),
                    Case(row: 7, session: Self.agents[0], label: "cursor", atMs: try stills(Self.agents[0])[2])]
        case 8:
            return [Case(row: 8, session: bash, label: "80x24", atMs: try still(bash, "small")),
                    Case(row: 8, session: bash, label: "100x32-again", atMs: try still(bash, "done")),
                    Case(row: 8, session: matrix, label: "landscape", atMs: try still(matrix, "edges"), step: .landscape),
                    Case(row: 8, session: Self.agents[2], label: "landscape", atMs: try stills(Self.agents[2])[2], step: .landscape)]
        case 9:
            return [Case(row: 9, session: matrix, label: "background", atMs: try still(matrix, "box"), step: .background),
                    Case(row: 9, session: Self.agents[0], label: "background", atMs: try stills(Self.agents[0])[2], step: .background)]
        default:
            return []
        }
    }

    /// Runs `rows` and hands each message for the Mac to `emit`: `{"case":{...}}` per case,
    /// then `{"done":true}`, or `{"error":...}` when nothing could run.
    func run(rows: [Int], emit: @MainActor ([String: Any]) async -> Void) async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            await emit(["error": "the app is not in the foreground: open cmux on the phone and run it again"])
            return
        }
        let stage = TerminalSelfCheckStage(scene: scene)
        defer { stage.tearDown() }
        log.info("self-check: rows \(rows.map(String.init).joined(separator: ","), privacy: .public)")
        for row in rows {
            let cases: [Case]
            do {
                cases = try self.cases(row: row)
            } catch {
                await emit(["case": ["row": row, "id": "row\(row)", "error": "\(error)"]])
                continue
            }
            for item in cases {
                let result = await measure(item, on: stage)
                await emit(["case": result])
            }
        }
        await emit(["done": true])
    }

    // MARK: One case

    private struct Side {
        let daemon: HybridBenchDaemon
        let terminal: DaemonTerminalSession
        let model: TerminalModel

        @MainActor init?(_ session: BenchSession, lean: Bool) {
            guard let defaults = SelfCheckDefaults(agentCLIHybrid: lean) else { return nil }
            let daemon = HybridBenchDaemon(session: session, hybrid: lean, lean: lean)
            let terminal = DaemonTerminalSession(
                surface: 1,
                open: { DaemonClient(channel: daemon.main, eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) },
                openInput: { DaemonClient(channel: daemon.lane, eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) }
            )
            terminal.agentCLIHybridDefaults = defaults
            self.daemon = daemon
            self.terminal = terminal
            model = TerminalModel(session: terminal, artifactSource: UnavailableArtifactSource(), title: "self-check")
        }
    }

    private func measure(_ item: Case, on stage: TerminalSelfCheckStage) async -> [String: Any] {
        var result: [String: Any] = [
            "row": item.row, "id": item.id, "session": item.session, "label": item.label, "at_ms": item.atMs,
            "pan_end": item.panEnd, "same_layout": item.sameLayout,
        ]
        let session: BenchSession
        do {
            session = try self.session(item.session)
        } catch {
            result["error"] = "\(error)"
            return result
        }
        guard let pty = Side(session, lean: false), let lean = Side(session, lean: true) else {
            result["error"] = "no settings of its own for the two screens"
            return result
        }
        stage.resize(to: nil)
        stage.show([pty.model, lean.model])
        defer {
            stage.show([])
            pty.terminal.stop()
            lean.terminal.stop()
        }
        // Both attached (the fake Macs answered the attach), then the session up to the frame.
        let clock = ContinuousClock()
        let attachDeadline = clock.now + .seconds(20)
        while pty.daemon.attachAt == nil || lean.daemon.attachAt == nil, clock.now < attachDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pty.daemon.attachAt != nil, lean.daemon.attachAt != nil else {
            result["error"] = "the terminal never attached (\(pty.daemon.attachAt == nil ? "pty" : "lean"))"
            return result
        }
        await settle(stage)
        let (ptyDaemon, leanDaemon, atMs, attachMs) = (pty.daemon, lean.daemon, item.atMs, session.attachMs)
        async let ptyPlayed: Void = Task.detached { await ptyDaemon.play(until: atMs, from: 0, attachMs: attachMs, fast: true) }.value
        async let leanPlayed: Void = Task.detached { await leanDaemon.play(until: atMs, from: 0, attachMs: attachMs, fast: true) }.value
        _ = await (ptyPlayed, leanPlayed)
        await settle(stage)
        switch item.step {
        case .none:
            break
        case .landscape:
            let size = stage.bounds.size
            stage.resize(to: CGSize(width: size.height, height: size.width))
            await settle(stage)
        case .background:
            stage.setShown(false)
            try? await Task.sleep(for: .milliseconds(1500))
            stage.setShown(true)
            await settle(stage)
        }
        if item.panEnd {
            stage.pan(toEnd: true)
            await settle(stage)
        }
        guard let a = stage.geometry(0), let b = stage.geometry(1) else {
            result["error"] = "no grid on the \(stage.geometry(0) == nil ? "PTY" : "lean") screen"
            return result
        }
        result["pty"] = Self.side(a, alternate: pty.terminal.isAlternateScreen)
        result["lean"] = Self.side(b, alternate: lean.terminal.isAlternateScreen)
        let area = a.grid.intersection(stage.bounds)
        guard !area.isNull, !area.isEmpty, let first = stage.pixels(0, in: area), let second = stage.pixels(1, in: area) else {
            result["error"] = "no presented frame under the grid"
            return result
        }
        var images: [String: String] = [:]
        images["pty"] = LeanSelfCheckDiff.png(first.image)?.base64EncodedString()
        images["lean"] = LeanSelfCheckDiff.png(second.image)?.base64EncodedString()
        guard let diff = LeanSelfCheckDiff(pty: first.image, lean: second.image, rect: first.rect, grid: a.grid, cell: a.cell,
                                           cursors: [a.cursor, b.cursor].compactMap { $0 }) else {
            result["images"] = images
            result["error"] = "the two frames differ in size (\(first.image.width)x\(first.image.height) and "
                + "\(second.image.width)x\(second.image.height) px)"
            return result
        }
        images["diff"] = LeanSelfCheckDiff.png(diff.image)?.base64EncodedString()
        result["images"] = images
        result["pixels"] = ["differing": diff.differing, "compared": diff.compared]
        result["bands"] = diff.bands.map { ["name": $0.name, "differing": $0.differing, "compared": $0.compared] }
        log.info("self-check \(item.id, privacy: .public): \(diff.differing)/\(diff.compared) px differ")
        return result
    }

    private static func rect(_ r: CGRect) -> [Double] {
        [r.minX, r.minY, r.width, r.height].map { (Double($0) * 100).rounded() / 100 }
    }

    private static func side(_ geometry: TerminalGridGeometry, alternate: Bool) -> [String: Any] {
        ["grid": rect(geometry.grid), "cursor": geometry.cursor.map { rect($0) as Any } ?? NSNull(),
         "full_screen": geometry.fullScreen, "alternate": alternate, "scale": Double(geometry.scale)]
    }

    /// Until neither screen presented a frame for 300 ms (at most 5 s).
    private func settle(_ stage: TerminalSelfCheckStage) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        var last = stage.presentedFrames
        var stableSince = clock.now
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
            let now = stage.presentedFrames
            if now != last {
                last = now
                stableSince = clock.now
            } else if clock.now - stableSince >= .milliseconds(300) {
                return
            }
        }
    }
}

struct SelfCheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One side's own answer to "lean frames on?" (`DaemonTerminalSession.agentCLIHybridDefaults`):
/// the self-check never reads or writes the person's setting.
final class SelfCheckDefaults: UserDefaults, @unchecked Sendable {
    private let agentCLIHybrid: Bool

    /// Nil only when Foundation has no defaults at all (`UserDefaults(suiteName: nil)` failed).
    init?(agentCLIHybrid: Bool) {
        self.agentCLIHybrid = agentCLIHybrid
        super.init(suiteName: nil)
    }

    override func bool(forKey key: String) -> Bool {
        key == DaemonTerminalSession.agentCLIHybridDefaultsKey ? agentCLIHybrid : super.bool(forKey: key)
    }
}
#endif
