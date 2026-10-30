import AppKit
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// What one sent-bubble draw pays to make its themed gradient (R10: FixtureTheme keeps the gradient's stops, not a
/// CGGradient, so it is checked Sendable; a row render, sometimes on the main thread inside its draw budget, makes the
/// gradient when it draws). Prints nanoseconds per creation (p50, p95, p99, max over `runs`), for the stops path the
/// draw takes (`Colors.outgoingGradient`: a CGGradient from the theme's ready CGColors) and, for comparison, for one
/// made from the palette's HomeColor stops (HomeColor -> CGColor -> CGGradient).
/// A measurement, not a gate: quote the `outgoing-gradient-cost` line.
@Suite(.serialized) struct OutgoingGradientCostBench {
    private static let runs = 20_000

    /// A themed palette with a full sent-bubble gradient (8 stops, as the measured Messages gradient has).
    private static func colors() -> FixtureTheme.Colors {
        let theme = HomePalette.Theme(background: .gray255(30), foreground: .gray255(230),
                                      accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58))
        var palette = HomePalette.iMessageStyled(theme)
        var stops: [HomePalette.GradientStop] = []
        for index in 0..<8 {
            let step = CGFloat(index)
            let location: CGFloat = step / 7
            let red: CGFloat = 90 - 4 * step
            let green: CGFloat = 154 - 2 * step
            let color: HomeColor = .rgb255(red, green, 247)
            stops.append(HomePalette.GradientStop(location: location, color: color))
        }
        palette.outgoingGradient = stops
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
        func q(_ p: Double) -> Int {
            let count: Int = sorted.count
            let slot: Int = min(count - 1, Int(Double(count) * p))
            return Int(sorted[checked: slot] ?? 0)
        }
        let maximum: Int = Int(sorted.last ?? 0)
        return "\(name) p50=\(q(0.5))ns p95=\(q(0.95))ns p99=\(q(0.99))ns max=\(maximum)ns"
    }

    @Test func gradientCreationPerDraw() {
        let colors = Self.colors()
        _ = Self.nanos { colors.outgoingGradient }  // warm
        let perDraw = Self.nanos { colors.outgoingGradient }
        let stops = colors.palette.outgoingGradient
        let fromStops = Self.nanos {
            CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { $0.color.cgColor } as CFArray,
                       locations: stops.map(\.location))
        }
        let drawLine = Self.line("perDraw", perDraw)
        let stopsLine = Self.line("fromHomeColorStops", fromStops)
        print("outgoing-gradient-cost runs=\(Self.runs) \(drawLine) | \(stopsLine)")
    }
}
