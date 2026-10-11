import Foundation

/// The cmux-cua macOS cursor motion (cursor-overlay
/// `RenderStateCore::tick_swift_constants`): a straight travel with a
/// smootherstep speed envelope, then a spring settle. Planned once per action
/// and sampled at `dt`; the samples become one keyframe animation, so the
/// render server interpolates and the app does no per-frame work.
public struct GlideMotion: Sendable, Equatable {
    public var peakSpeed: Double = 900
    public var minStartSpeed: Double = 300
    public var minEndSpeed: Double = 200
    public var springStiffness: Double = 400
    public var springDamping: Double = 17
    public var springOvershoot: Double = 0.8
    public var dt: Double = 1.0 / 120.0

    public init() {}
}

public struct GlideSample: Sendable, Equatable {
    public var x: Double
    public var y: Double
    /// Arrow heading in radians (tip direction).
    public var heading: Double
}

public struct GlidePlan: Sendable, Equatable {
    /// One sample per `dt` tick, starting after the first tick.
    public var samples: [GlideSample]
    /// 1-based tick at which the travel ended and the spring began.
    public var arrivedTick: Int
    public var dt: Double

    /// Where the glide started.
    public var origin: CGPoint
    public var duration: Double { Double(samples.count) * dt }
}

extension GlideMotion {
    /// Same integration as the Rust renderer, tick by tick: travel along the
    /// straight path (the Dubins plan with equal start and end headings) at
    /// `floor + (peak - floor) * 30u²(1-u)²/1.875`, then a spring released
    /// with `speed * overshoot` along the travel direction, integrated in 4
    /// substeps until offset < 0.3 and velocity < 2.
    public func plan(fromX x0: Double, fromY y0: Double, toX x1: Double, toY y1: Double, endHeading: Double) -> GlidePlan {
        let travel = atan2(y1 - y0, x1 - x0)
        let distance = hypot(x1 - x0, y1 - y0)
        let straight = distance >= 0.5
        let length = straight ? distance : max(distance, 1)
        var samples: [GlideSample] = []
        var travelled = 0.0
        var arrivedTick = 0
        var target = (x: x1, y: y1)
        var spring = (ox: 0.0, oy: 0.0, vx: 0.0, vy: 0.0)
        let maxTicks = 20_000
        var tick = 0
        while tick < maxTicks {
            tick += 1
            if arrivedTick == 0 {
                let u = min(travelled / length, 1)
                let profile = (30 * u * u * (1 - u) * (1 - u)) / 1.875
                let floor = u < 0.5 ? minStartSpeed : minEndSpeed
                let speed = floor + (peakSpeed - floor) * profile
                travelled += speed * dt
                if travelled >= length {
                    arrivedTick = tick
                    target = straight ? (x0 + cos(travel) * length, y0 + sin(travel) * length) : (x1, y1)
                    spring = (0, 0, speed * springOvershoot * cos(travel), speed * springOvershoot * sin(travel))
                    samples.append(GlideSample(x: target.x, y: target.y, heading: endHeading))
                } else {
                    samples.append(GlideSample(
                        x: x0 + cos(travel) * travelled,
                        y: y0 + sin(travel) * travelled,
                        heading: travel + .pi
                    ))
                }
                continue
            }
            let step = dt / 4
            for _ in 0..<4 {
                spring.vx += (-springStiffness * spring.ox - springDamping * spring.vx) * step
                spring.vy += (-springStiffness * spring.oy - springDamping * spring.vy) * step
                spring.ox += spring.vx * step
                spring.oy += spring.vy * step
            }
            if hypot(spring.ox, spring.oy) < 0.3 && hypot(spring.vx, spring.vy) < 2 {
                samples.append(GlideSample(x: target.x, y: target.y, heading: endHeading))
                break
            }
            samples.append(GlideSample(x: target.x + spring.ox, y: target.y + spring.oy, heading: endHeading))
        }
        return GlidePlan(samples: samples, arrivedTick: arrivedTick, dt: dt, origin: CGPoint(x: x0, y: y0))
    }
}
