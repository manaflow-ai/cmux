@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Foundation
import Testing

/// The main-thread cost of a hover sweep over the sidebar, in nanoseconds per pointer move: what
/// `HoverCardCoordinator.pointerMoved` asks of the hover rules on each move (the safe-triangle
/// test against the shown card, then one `HoverCardMachine` event), over a pointer that rests on
/// a row until its card opens, then sweeps down 60 rows and back with the card following, with
/// gaps, aims and deadlines between. p50, p95, p99 and max. A measurement, not a gate: the A/B of
/// the Swift rules against the Rust call (B8 step B) runs it alone on an exclusive host with the
/// rules of each arm (`restore=` the Swift files of the base for arm A).
///
/// ```
/// CMUX_HOVER_SWEEP_BENCH=1 swift test -c release --filter HoverCardSweepBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_HOVER_SWEEP_BENCH"] == "1"))
struct HoverCardSweepBench {
    private static let rows = 60
    private static let rounds = 400

    private static func row(_ n: Int) -> HoverTarget {
        HoverTarget(id: HoverTargetID("ws:\(n)"), window: 7, delay: HoverCardTiming.showDelay,
                    leave: .hides(reshow: HoverCardTiming.reshowWindow))
    }

    /// One pointer move: the aim test against the card beside the row near `point`, then the
    /// machine's event (`n` the row under the pointer, nil in the gap after a row).
    private static func move(_ machine: inout HoverCardMachine, to n: Int?, from: CGPoint, to point: CGPoint,
                             targets: [HoverTarget]) -> Int {
        let card = CGRect(x: 240, y: point.y - 160, width: 280, height: 160)
        let aiming = card.isAimedAt(from: from, to: point)
        let target = n.map { targets[$0] }
        return machine.reduce(.hit(target, moved: true, aiming: aiming, bridging: n == nil)).count
    }

    @Test func nanosecondsPerPointerMove() {
        let targets = (0..<Self.rows).map(Self.row)
        var samples: [UInt64] = []
        samples.reserveCapacity(Self.rounds * Self.rows * 4)
        var sink = 0
        for round in 0..<(Self.rounds + 20) {
            var machine = HoverCardMachine()
            var last = CGPoint(x: 120, y: 890)
            // Rest on row 0 until its card opens.
            sink &+= machine.reduce(.hit(targets[0], moved: true)).count
            if let token = machine.armedToken { sink &+= machine.reduce(.deadline(token: token)).count }
            // Down the list and back up: each row twice (its middle, then the gap after it).
            let path = Array(0..<Self.rows) + Array((0..<Self.rows).reversed())
            for n in path {
                for step in 0..<2 {
                    let point = CGPoint(x: 120 + CGFloat(step), y: 890 - CGFloat(n) * 28 - CGFloat(step) * 14)
                    let start = DispatchTime.now().uptimeNanoseconds
                    sink &+= Self.move(&machine, to: step == 0 ? n : nil, from: last, to: point, targets: targets)
                    let end = DispatchTime.now().uptimeNanoseconds
                    if round >= 20 { samples.append(end - start) }  // the first rounds warm up
                    last = point
                }
                // A deadline every tenth row, as the coordinator's timer fires it.
                if n % 10 == 0, let token = machine.armedToken {
                    sink &+= machine.reduce(.pointerOnCard(false)).count
                    sink &+= machine.reduce(.deadline(token: token)).count
                }
            }
        }
        samples.sort()
        func quantile(_ q: Double) -> UInt64 { samples[min(samples.count - 1, Int(Double(samples.count) * q))] }
        print("hover-card sweep bench: macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
              + "\(samples.count) pointer moves over \(Self.rows) rows: p50 \(quantile(0.5)) ns, p95 \(quantile(0.95)) ns, "
              + "p99 \(quantile(0.99)) ns, max \(samples.last ?? 0) ns (sink \(sink & 1))")
        #expect(samples.count == Self.rounds * Self.rows * 4)
    }
}
