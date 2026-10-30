import AppKit
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// What one sent-bubble draw pays to make its themed gradient (R10: FixtureTheme keeps the gradient's stops, not a
/// CGGradient, so it is checked Sendable; a row render, sometimes on the main thread inside its draw budget, makes the
/// gradient when it draws). Prints nanoseconds per creation (p50, p95, p99, max over `runs`), for the stops path the
/// draw takes (`Colors.outgoingGradient`: HomeColor -> CGColor -> CGGradient) and for a gradient from ready CGColors.
/// A measurement, not a gate: quote the `outgoing-gradient-cost` line.
@Suite(.serialized) struct OutgoingGradientCostBench {
    private static let runs = 20_000

    /// A themed palette with a full sent-bubble gradient (8 stops, as the measured Messages gradient has).
    private static func colors() -> FixtureTheme.Colors {
        var palette = HomePalette.iMessageStyled(.init(background: .gray255(30), foreground: .gray255(230),
                                                       accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58)))
        palette.outgoingGradient = (0..<8).map { i in
            HomePalette.GradientStop(location: CGFloat(i) / 7, color: .rgb255(CGFloat(90 - 4 * i), CGFloat(154 - 2 * i), 247))
        }
        return FixtureTheme.Colors(palette, measured: false)
    }

    private static func nanos(_ body: () -> CGGradient?) -> [Double] {
        var out = [Double](); out.reserveCapacity(runs)
        var made = 0
        for _ in 0..<runs {
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if body() != nil { made += 1 }
            out.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0))
        }
        #expect(made == runs)
        return out.sorted()
    }

    private static func line(_ name: String, _ sorted: [Double]) -> String {
        func q(_ p: Double) -> Int { Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) }
        return "\(name) p50=\(q(0.5))ns p95=\(q(0.95))ns p99=\(q(0.99))ns max=\(Int(sorted.last ?? 0))ns"
    }

    @Test func gradientCreationPerDraw() {
        let colors = Self.colors()
        _ = Self.nanos { colors.outgoingGradient }  // warm
        let fromStops = Self.nanos { colors.outgoingGradient }
        let ready = colors.palette.outgoingGradient.map { $0.color.cgColor } as CFArray
        let locations = colors.palette.outgoingGradient.map(\.location)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let fromReady = Self.nanos { CGGradient(colorsSpace: space, colors: ready, locations: locations) }
        print("outgoing-gradient-cost runs=\(Self.runs) " + Self.line("stops", fromStops) + " | " + Self.line("readyColors", fromReady))
    }
}
