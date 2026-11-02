import CmuxNextDesign
import CmuxNextLayout
import CoreGraphics
import Foundation
import Testing

/// Bit-for-bit trace of the column scroll reducer under the command-pan bench's gestures, to compare
/// two code versions: the Swift reducer at the B1 base and the Rust reducer (cmux_scroll_*) at the
/// head. Not a gate and off unless CMUX_COLUMN_SCROLL_PARITY=1; the same file runs on both refs and
/// each run prints its trace, which the two runs' logs compare.
///
/// The input is the bench's (scripts/cmux-next/bench-command-pan.py `gesture`, LayoutRootView+Scroll,
/// ScreenContentView+Scrolling): per gesture `began` (gestureBegan, then gestureChanged with its dx),
/// 40 `changed` of the same dx one 120 Hz frame apart, and `ended` (gestureEnded); 12 gestures
/// alternating +24 / -24 points, as 6 Command rounds and 6 base rounds. A focus the scroll moved comes
/// back as the model's sync (source scroll). The spring steps at 120 Hz on the scroll spring until it
/// rests. The strip is the app's: ScreenGeometry of four columns (the workspace column and three New
/// Column columns at two thirds), through ColumnStrip(layout:geometry:gap:). Three event clocks: all
/// timestamps 0 (a synthesized event that carries none), exact 1/120 s steps from a boot-time offset,
/// and steps with a fixed jitter.
///
/// ```
/// CMUX_COLUMN_SCROLL_PARITY=1 swift test --filter ColumnScrollReleaseParityTrace
/// ```
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_COLUMN_SCROLL_PARITY"] == "1"))
struct ColumnScrollReleaseParityTrace {
    private static let dt = 1.0 / 120.0
    private static let spring = SpringParameters(response: 0.2, dampingFraction: 0.9)

    private enum Clock: String, CaseIterable {
        case zero, exact, jitter

        func time(_ tick: Int) -> TimeInterval {
            switch self {
            case .zero: 0
            case .exact: 411_844.428_250_375 + Double(tick) / 120
            case .jitter: 411_844.428_250_375 + Double(tick) / 120 + 0.002 * sin(Double(tick) * 1.7)
            }
        }
    }

    /// FNV-1a over the trace lines, so two runs compare by one number per case.
    private struct Digest {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        var lines = 0
        mutating func add(_ line: String) {
            for byte in line.utf8 {
                value ^= UInt64(byte)
                value = value &* 0x0000_0100_0000_01b3
            }
            lines += 1
        }
    }

    private static func bits(_ value: CGFloat) -> String { String(Double(value).bitPattern, radix: 16) }

    private static func strip(viewport: CGSize) -> ColumnStrip? {
        let columns = [LayoutColumn(id: ColumnID("c0"), width: 1, root: .leaf(PaneID("p0")))]
            + (1...3).map { LayoutColumn(id: ColumnID("c\($0)"), width: 2.0 / 3.0, root: .leaf(PaneID("p\($0)"))) }
        let layout = ScreenLayout.columns(columns)
        let style = LayoutStyle()
        let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: style)
        return ColumnStrip(layout: layout, geometry: geometry, gap: style.stripGap)
    }

    @Test func traceCommandPanGestures() throws {
        for width in [1280.0, 1440.0, 1920.0] {
            let strip = try #require(Self.strip(viewport: CGSize(width: width, height: 1000)))
            for clock in Clock.allCases {
                var digest = Digest()
                var state = ColumnScrollState()
                var tick = 0
                func record(_ label: String, _ effects: ColumnScrollEffects?) {
                    let s = state.spring
                    var line = "\(label) v=\(Self.bits(s.value)) vel=\(Self.bits(s.velocity)) t=\(Self.bits(s.target))"
                    line += " focus=\(state.focusedPane?.rawValue ?? "-") g=\(state.isGestureActive)"
                    if let effects {
                        line += " frames=\(effects.needsFrames) efocus=\(effects.focus?.rawValue ?? "-") settle=\(effects.reportOnSettle) snapped=\(effects.snapped)"
                    }
                    digest.add(line)
                }
                record("sync0", state.reduce(.sync(strip, focused: PaneID("p3"), source: .programmatic, animated: false)))
                for round in 0..<12 {
                    let dx: CGFloat = round.isMultiple(of: 2) ? 24 : -24
                    record("r\(round) began", state.reduce(.gestureBegan))
                    record("r\(round) c0", state.reduce(.gestureChanged(deltaX: dx, time: clock.time(tick))))
                    for step in 1...40 {
                        tick += 1
                        _ = state.spring.advance(Self.dt, parameters: Self.spring, epsilon: 0.25)
                        record("r\(round) c\(step)", state.reduce(.gestureChanged(deltaX: dx, time: clock.time(tick))))
                    }
                    tick += 1
                    let ended = state.reduce(.gestureEnded(time: clock.time(tick), animated: true))
                    record("r\(round) ended", ended)
                    let releaseTarget = state.spring.target, releaseVelocity = state.spring.velocity
                    if let pane = ended.focus {
                        record("r\(round) echo", state.reduce(.sync(strip, focused: pane, source: .scroll, animated: true)))
                    }
                    var frames = 0
                    while frames < 600 {
                        tick += 1
                        frames += 1
                        let moving = state.spring.advance(Self.dt, parameters: Self.spring, epsilon: 0.25)
                        record("r\(round) f\(frames)", nil)
                        if !moving { break }
                    }
                    print("column-scroll parity w=\(Int(width)) clock=\(clock.rawValue) r\(round) dx=\(dx): release target "
                          + "\(releaseTarget) (\(Self.bits(releaseTarget))) velocity \(releaseVelocity) (\(Self.bits(releaseVelocity))) "
                          + "focus \(ended.focus?.rawValue ?? "-") rest at \(state.spring.value) after \(frames) frames")
                    tick += 30  // the bench's pause between rounds
                }
                print("column-scroll parity digest w=\(Int(width)) clock=\(clock.rawValue): \(String(digest.value, radix: 16)) over \(digest.lines) lines")
            }
        }
    }
}
