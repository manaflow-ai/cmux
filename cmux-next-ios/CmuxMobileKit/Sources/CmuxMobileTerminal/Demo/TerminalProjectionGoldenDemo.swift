#if os(iOS) && DEBUG
import SwiftUI
import UIKit

/// DEBUG only. The projection's golden cases on the real terminal page, for
/// Mac-versus-phone screenshots (Leo, 2026-11-17: "how's the lean terminal
/// view on phone? proven upholding behaviour yet? headers left right end of
/// terminal lines etc?").
///
/// `-CmuxMobileProjectionGolden NAME [-CmuxMobileProjectionGoldenSide mac|phone]`
/// feeds case NAME's program bytes, exactly as the Rust golden test fed them
/// (cmux-tui/crates/cmux-terminal-projection/tests/golden.rs, written to
/// `vt/NAME.vt` by its `GOLDEN_OUT` run and turned into
/// TerminalProjectionGoldenFixtures.swift by
/// cmux-next-ios/scripts/gen-projection-golden-fixtures.py), from a Mac pane
/// at the case's grid (120x24 or 120x40):
///
/// - `phone` (default): the session the app builds for a Mac terminal
///   (`TerminalSessionChoice.session(live:)`, the real
///   `TerminalProjectingSession`) on the real workspace terminal page, at the
///   phone's own grid.
/// - `mac`: the same bytes with no projection, on a page laid out at the
///   Mac's grid and scaled down to the screen: the Mac pane's layout.
///
/// The bytes are fed in the golden's stages (its snapshots), one stage every
/// ``stageSeconds``; `debug.terminal-demo` reads
/// `golden.<name>.<side>.<stage index>.<stage>` once a stage is on screen
/// (then `.done` after the last), and `debug.golden-text` the surface's rows,
/// for the UI test to attach beside the screenshot.
/// `rotation_and_keyboard` also shows and hides the keyboard
/// (`.kbup`, `.kbdown`). After `.done` the UI test turns the phone, and for
/// `scrollback_reaches_line_one` swipes up through the history the way a
/// person does (the page asks for older rows only while a finger drags or a
/// fling decelerates); `debug.golden-text` names the oldest row held.
public struct TerminalProjectionGoldenRoot: View {
    @State private var model: TerminalModel
    @State private var host: TerminalTabHost
    @State private var cell: CGSize = .zero
    private let golden: TerminalProjectionGoldenCase
    private let mac: GoldenMacPaneSession
    private let side: Side

    enum Side: String { case mac, phone }

    public static var isRequested: Bool { requestedName != nil }

    static var requestedName: String? { UserDefaults.standard.string(forKey: "CmuxMobileProjectionGolden") }

    static let stageSeconds = 6.0

    public init() {
        let name = Self.requestedName ?? ""
        let golden = TerminalProjectionGoldenCase.all.first { $0.name == name } ?? TerminalProjectionGoldenCase.missing(name)
        let side = Side(rawValue: UserDefaults.standard.string(forKey: "CmuxMobileProjectionGoldenSide") ?? "") ?? .phone
        let mac = GoldenMacPaneSession(golden: golden)
        let session: any TerminalSession = side == .phone
            ? TerminalSessionChoice.session(live: mac, mockDataEnabled: false, macName: "Mac", programName: mac.programName)
            : mac
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "\(mac.programName) — golden \(golden.name)")
        self.golden = golden
        self.mac = mac
        self.side = side
        _model = State(initialValue: model)
        _host = State(initialValue: TerminalTabHost(model: model))
    }

    public var body: some View {
        Group {
            switch side {
            case .phone:
                TerminalTabPage(host: host, insets: EdgeInsets(top: 62, leading: 0, bottom: 90, trailing: 0), isInteractive: true)
            case .mac:
                macPane
            }
        }
        .overlay(alignment: .topLeading) {
            VStack {
                Text(model.demoNote)
                    .accessibilityIdentifier("debug.terminal-demo")
                Text(goldenText)
                    .accessibilityIdentifier("debug.golden-text")
            }
            .font(.system(size: 2))
            .foregroundStyle(.clear)
            .allowsHitTesting(false)
        }
        .task { await run() }
    }

    @State private var goldenText = "-"

    /// The page at the Mac's grid, scaled to fit the screen. The page's own
    /// grid is at least the Mac's columns and the session says the Mac's grid,
    /// so the mirror is exactly `macColumns` wide (TerminalHostGridLayout).
    private var macPane: some View {
        GeometryReader { proxy in
            let cell = self.cell.width > 0 ? self.cell : CGSize(width: 7.2, height: 15)
            // Side padding and a column to spare; the key bar and composer below.
            let width = CGFloat(golden.macColumns + 2) * cell.width + 24
            let height = CGFloat(golden.macRows) * cell.height + 150
            let scale = min(1, proxy.size.width / width, proxy.size.height / height)
            TerminalTabPage(host: host, insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0), isInteractive: true)
                .frame(width: width, height: height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    private func wait(_ seconds: Double) async {
        try? await ContinuousClock().sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func note(_ label: String) {
        model.demoNote = "golden.\(golden.name).\(side.rawValue).\(label)"
        print("[projection-golden] \(model.demoNote) grid=\(model.controller?.surface.grid.columns ?? -1)x\(model.controller?.surface.grid.rows ?? -1) mac-pty-resizes-asked=\(mac.resizesAsked)")
    }

    /// The surface's rows (the last screenful and a few above), one per line,
    /// `↩` where Ghostty soft-wrapped: the phone's side of the golden text.
    private func readBack() {
        guard let surface = model.controller?.surface else { return }
        let grid = surface.grid
        var out = "grid \(grid.columns)x\(grid.rows)\(model.isTUI ? " alternate screen" : "") side \(side.rawValue)"
        out += " mac \(golden.macColumns)x\(golden.macRows) mac-pty-resizes-asked \(mac.resizesAsked)\n"
        if let rows = surface.screenRows() {
            // The oldest row the page holds: the scrollback test swipes until it is line 0001.
            out += "held \(rows.rows.count) rows, oldest |\(rows.rows.first ?? "")|\n"
            let keep = grid.rows + 12
            let first = max(0, rows.rows.count - keep)
            for index in first..<rows.rows.count {
                out += String(format: "%5d|", index) + rows.rows[index] + "|" + (rows.wraps[index] ? "↩" : "") + "\n"
            }
        }
        goldenText = out
    }

    private func run() async {
        note("0.attach")
        // The page measures, the session starts.
        for _ in 0..<40 {
            await wait(0.25)
            if let size = model.controller?.surface.cellSize, size.width > 0 { cell = size; break }
        }
        await wait(1.5)
        for (index, stage) in golden.stages.enumerated() {
            await mac.feed(through: stage.end, streamed: stage.streamed, halfway: { [self] in
                // A streamed stage: a shot while it streams.
                readBack()
                note("\(index + 1).\(stage.name).streaming")
            })
            await wait(1.5)
            readBack()
            note("\(index + 1).\(stage.name)")
            await wait(Self.stageSeconds)
        }
        switch golden.name {
        case "rotation_and_keyboard":
            model.toggleKeyboard()
            await wait(2.5)
            readBack()
            note("\(golden.stages.count + 1).kbup")
            await wait(Self.stageSeconds)
            model.toggleKeyboard()
            await wait(2.5)
            readBack()
            note("\(golden.stages.count + 2).kbdown")
            await wait(Self.stageSeconds)
        default:
            break
        }
        // The test rotates the phone after `.done`; the rows keep up.
        note("done")
        for _ in 0..<240 {
            await wait(1)
            readBack()
        }
    }
}

/// One golden case: the program's bytes and where the golden's snapshots fall.
struct TerminalProjectionGoldenCase: Sendable {
    struct Stage: Sendable {
        let name: String
        /// Bytes fed once the stage is on screen.
        let end: Int
        /// Fed in small chunks over a few seconds (live output).
        let streamed: Bool
    }

    let name: String
    let about: String
    let macColumns: Int
    let macRows: Int
    /// The phone grid the golden text was made at (the simulator's may differ).
    let goldenPhoneColumns: Int
    let goldenPhoneRows: Int
    let stages: [Stage]
    let base64: String

    var bytes: Data { Data(base64Encoded: base64) ?? Data() }

    static func missing(_ name: String) -> TerminalProjectionGoldenCase {
        let text = "no golden case '\(name)'; cases: " + all.map(\.name).joined(separator: ", ") + "\r\n"
        return .init(name: name, about: "", macColumns: 120, macRows: 24, goldenPhoneColumns: 54, goldenPhoneRows: 38,
                     stages: [.init(name: "final", end: text.utf8.count, streamed: false)],
                     base64: Data(text.utf8).base64EncodedString())
    }
}

/// A Mac pane at the golden's grid that writes the golden's program bytes.
/// Like `MacPaneMockSession` it is what the phone's sizing sees of a Mac
/// pane, but its program is a recording: it never resizes. A claim the
/// phone makes (the projection claims for the alternate screen) is counted
/// in ``resizesAsked`` and shown in the read-back, not applied, so the
/// screenshots show the bytes the golden was made from.
@MainActor
final class GoldenMacPaneSession: TerminalSession {
    let golden: TerminalProjectionGoldenCase
    private let data: Data
    private var fed = 0
    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?
    private var detector = AlternateScreenDetector()
    private(set) var resizesAsked = 0
    private var claims = false

    init(golden: TerminalProjectionGoldenCase) {
        self.golden = golden
        data = golden.bytes
    }

    var programName: String {
        if golden.name.contains("codex") { return "codex" }
        if golden.name.contains("claude") || golden.name == "rotation_and_keyboard" { return "claude" }
        return "zsh"
    }

    var isAlternateScreen: Bool { detector.isActive }
    var remoteColumns: Int? { golden.macColumns }
    var remoteRows: Int? { golden.macRows }

    func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
        handler(.connection(.attached))
        handler(.hostGrid(columns: golden.macColumns, rows: golden.macRows))
        // The Mac's replay of an empty pane: a reset, then nothing yet.
        handler(.output(TerminalReclaimHold.reset))
        if fed > 0 { emit(data.prefix(fed)) }
    }

    /// Feeds the program's bytes up to `end`: at once, or streamed in 48-byte
    /// chunks every 16 ms (about 3 KB/s, a live build), calling `halfway`
    /// once in the middle.
    func feed(through end: Int, streamed: Bool, halfway: () -> Void) async {
        let end = min(end, data.count)
        guard end > fed else { return }
        guard streamed else {
            let chunk = data.subdata(in: fed..<end)
            fed = end
            emit(chunk)
            return
        }
        let middle = fed + (end - fed) / 2
        var calledHalfway = false
        while fed < end {
            let next = min(end, fed + 48)
            let chunk = data.subdata(in: fed..<next)
            fed = next
            emit(chunk)
            try? await ContinuousClock().sleep(for: .milliseconds(16))
            if !calledHalfway, fed >= middle {
                calledHalfway = true
                try? await ContinuousClock().sleep(for: .milliseconds(800))
                halfway()
                try? await ContinuousClock().sleep(for: .milliseconds(2500))
            }
        }
    }

    private func emit(_ chunk: Data) {
        if let alternate = detector.scan(chunk) { handler?(.alternateScreen(alternate)) }
        handler?(.output(chunk))
    }

    func send(_ bytes: Data) {}
    func resize(columns: Int, rows: Int) {
        if claims { resizesAsked += 1 }
    }
    func setClaimsSize(_ claims: Bool) { self.claims = claims }
    func stop() { handler = nil }
}
#endif
