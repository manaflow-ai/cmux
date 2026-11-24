// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// The agent cursor's tail as a small living creature: a pure, deterministic model of its
/// motion, stepped once per display frame by the overlay (``AgentCursorOverlay``) and by the
/// offscreen frame renders.
///
/// The tail is a chain of five segments hanging from the pointer's stem. Each joint is a damped
/// angular spring toward its pose (the cursor's soft S), so the chain carries motion from the
/// root to the tip and settles with an overshoot. The pointer's real motion drives it as
/// secondary motion: air drag against the pointer's velocity streams it behind a move, and its
/// inertia against the pointer's acceleration swings it when a move starts and stops. On top of
/// the pose runs a slow travelling wave made of four sines with incommensurate frequencies (so
/// it never visibly repeats), occasional subtle flicks at seeded random times, a happy flick per
/// click or key, an excited wiggle while typing, slower and calmer motion while the agent waits,
/// and a droop while it is paused or refused.
///
/// The model never moves the pointer: the root stays on the stem's end and the click lands where
/// the tip is. Its output is the chain's points in the pointer's design grid (y up, the units of
/// ``SessionCursor/pointerPath``), drawn as a smooth curve through them. Without animation
/// (``animates`` false: the app's cursor switches or Reduce Motion) it is always the rest pose.
struct AgentCursorTail {
    /// Segments in the chain.
    static let segmentCount = 5

    /// The pointer's outline (design grid, y up, tip first): the shape the tail never enters.
    static let pointerOutline: [CGPoint] = [
        CGPoint(x: 2.5, y: 26), CGPoint(x: 2.5, y: 6.5), CGPoint(x: 7.6, y: 11.2), CGPoint(x: 11.0, y: 3.4),
        CGPoint(x: 15.0, y: 5.2), CGPoint(x: 11.9, y: 12.8), CGPoint(x: 19.0, y: 12.8),
    ]
    /// Where the tail leaves the pointer: the middle of the stem's end.
    static let root = CGPoint(x: 12.8, y: 5.0)
    /// The tail at rest, the cursor's soft S: one cubic from the root (start, control 1,
    /// control 2, end).
    static let restCurve: [CGPoint] = [
        root, CGPoint(x: 13.3, y: -1.0), CGPoint(x: 21.3, y: 3.5), CGPoint(x: 21.8, y: -3.0),
    ]

    /// The tuning. Angles in radians, lengths in design-grid units, times in seconds.
    struct Tuning: Sendable {
        /// Joint springs, root to tip (angular stiffness per unit inertia at the root).
        var jointStiffness: [Double] = [150, 125, 105, 88, 72]
        /// Segment inertia, root to tip: a lighter tip whips more.
        var segmentInertia: [Double] = [1.0, 0.8, 0.62, 0.48, 0.38]
        /// Damping ratio of every joint (under 1: it overshoots and settles).
        var zeta = 0.38
        /// Damping against each segment's own swing (air), per second.
        var air = 2.2
        /// Air drag against the pointer's velocity, saturating at `dragSaturation` units/s.
        var drag = 0.075
        var dragSaturation = 320.0
        /// Inertia against the pointer's acceleration, saturating at `accelSaturation` units/s².
        var inertia = 0.0026
        var accelSaturation = 7000.0
        /// The idle wave: four sines (Hz), irrational ratios 1 : √2 : φ : 1/π of 0.31 Hz, so
        /// the sum never repeats. Each has an amplitude (rad per joint) and a phase lag per joint
        /// (rad), which makes it travel from the root to the tip.
        var waveFrequencies: [Double] = [0.31, 0.31 * 2.0.squareRoot(), 0.31 * (1 + 5.0.squareRoot()) / 2, 0.31 / Double.pi]
        var waveAmplitudes: [Double] = [0.11, 0.07, 0.045, 0.08]
        var waveLags: [Double] = [0.6, 0.75, 0.5, 0.25]
        /// Idle flicks: one every `flickGap` seconds (seeded random), a kick of `flickKick` rad/s.
        var flickGap: ClosedRange<Double> = 2.8...7.0
        var flickKick = 2.6
        /// A click's happy flick and a key's smaller one (rad/s at the tip).
        var clickKick = 9.0
        var keyKick = 4.0
        /// Typing's excited wiggle: a fast travelling wave that fades with `wiggleDecay`.
        var wiggleFrequency = 3.6
        var wiggleAmplitude = 0.3
        var wiggleLag = 0.9
        var wiggleDecay = 0.9
        /// Calm: after `calmAfter` s without an event the wave slows to 65% and its amplitude to 75%.
        var calmAfter = 1.2
        var calmEase = 0.8
        /// Droop (paused, refused): the tail eases into a limp hang in `droopEase` s.
        var droopEase = 0.35
        /// Stretch with speed, up to `stretchMax` of its length, on a spring.
        var stretchMax = 0.22
        var stretchHalfSpeed = 250.0
        var stretchSpring = 90.0
        var stretchFriction = 9.0
        /// Limits: every segment points within `directions` (from left-and-a-little-down, round
        /// through down, to right-and-a-little-up; never up into the pointer, so the tail can never
        /// curl behind the arrow), and no joint bends more than maxBend from its pose.
        var directions: ClosedRange<Double> = (-165.0 * .pi / 180)...(20.0 * .pi / 180)
        var maxBend = 58.0 * .pi / 180
        /// The longest substep of the integration.
        var maxSubstep = 1.0 / 240
    }

    let tuning: Tuning
    /// False: the static rest pose, always (no animation, Reduce Motion). Turning it off settles
    /// the tail at rest with no spin and forgets the pointer, so turning it back on starts from
    /// rest instead of an old pose.
    var animates: Bool {
        didSet {
            if !animates {
                settleAtRest()
                teleport()
            }
        }
    }

    /// The rest pose: lengths and absolute and relative angles of each segment.
    static let rest: (points: [CGPoint], lengths: [Double], absolute: [Double], relative: [Double]) = restPose()
    /// The droop pose's relative angles: hanging down, a little curled.
    static let droopRelative: [Double] = {
        let absolute = (0..<segmentCount).map { (-100.0 + 7 * Double($0)) * .pi / 180 }
        return relative(absolute)
    }()

    // State. Every array has `segmentCount` entries (or one per wave), allocated once.
    private(set) var angles: [Double]
    private var spins: [Double]
    private var phases: [Double]
    private var rates: [Double]
    private var wigglePhase = 0.0
    private(set) var excitement = 0.0
    private(set) var calm = 0.0
    private var sinceEvent = 0.0
    /// Seconds since something outside stirred the tail (pointer motion, a click, a key, typing,
    /// a droop changing): ``isLively``.
    private var sinceStir = 0.0
    private(set) var droop = 0.0
    var drooping = false
    private(set) var stretch = 0.0
    private var stretchSpeed = 0.0
    private var untilFlick: Double
    private var flickSide: Double
    private var random: SplitMix64
    private var velocity = CGVector.zero
    private var acceleration = CGVector.zero
    private var lastPointer: CGPoint?
    // Scratch, reused every substep (no allocation per frame).
    private var scratchPoints: [CGPoint]
    private var scratchTarget: [Double]
    private var scratchError: [Double]
    private var scratchTorque: [Double]
    private var scratchAngles: [Double]
    private let damping: [Double]

    /// A tail for `session`: its wave phases, rates and flicks are seeded from the session id,
    /// so two agents' cursors never move in step.
    init(session: String, animates: Bool, tuning: Tuning = Tuning()) {
        self.tuning = tuning
        self.animates = animates
        var random = SplitMix64(seed: Self.fnv1a(session))
        angles = Self.rest.absolute
        spins = Array(repeating: 0, count: Self.segmentCount)
        phases = tuning.waveFrequencies.map { _ in random.unit() * 2 * .pi }
        // ±4% per session, so cursors that start together drift apart.
        rates = tuning.waveFrequencies.map { $0 * (0.96 + 0.08 * random.unit()) }
        // The first flick comes sooner than the rest (about 1.5 to 5 s with the default gap).
        untilFlick = tuning.flickGap.lowerBound * (0.55 + 1.25 * random.unit())
        flickSide = random.unit() < 0.5 ? 1 : -1
        self.random = random
        scratchPoints = Array(repeating: .zero, count: Self.segmentCount + 1)
        scratchTarget = Array(repeating: 0, count: Self.segmentCount)
        scratchError = Array(repeating: 0, count: Self.segmentCount)
        scratchTorque = Array(repeating: 0, count: Self.segmentCount)
        scratchAngles = Array(repeating: 0, count: Self.segmentCount)
        damping = (0..<Self.segmentCount).map {
            2 * tuning.zeta * (tuning.jointStiffness[$0] * tuning.segmentInertia[$0]).squareRoot()
        }
    }

    // MARK: Events

    /// A click: a quick happy flick, alternating sides.
    mutating func click() {
        sinceStir = 0
        kick(tuning.clickKick * flickSide)
        flickSide = -flickSide
        sinceEvent = 0
    }

    /// A key press: a smaller flick.
    mutating func key() {
        sinceStir = 0
        kick(tuning.keyKick * flickSide)
        flickSide = -flickSide
        sinceEvent = 0
    }

    /// Typing: an excited wiggle that fades over about a second.
    mutating func typing() {
        excitement = 1
        sinceEvent = 0
        sinceStir = 0
    }

    /// What a step of the agent means to the tail: a click flicks it, a key flicks it less,
    /// typing makes it wiggle, a move or a drag (the pointer is about to glide) stirs it so it
    /// follows from the first frame, anything else wakes it from calm. (Paused and refused droop
    /// it through the alert tint.)
    mutating func note(_ kind: AgentCursorEvent.Kind) {
        switch kind {
        case .click: click()
        case .typing: typing()
        case .keys: key()
        case .move, .drag: stir()
        default: activity()
        }
    }

    /// Any other step of the agent: wakes it from calm. (It stirs the tail only through the
    /// pointer's motion, if the step moves the pointer: a look in place stays at the idle rate.)
    mutating func activity() {
        sinceEvent = 0
    }

    /// The pointer is about to move (a glide or a drag starts): the tail follows it frame by
    /// frame from now, before its velocity has registered.
    mutating func stir() {
        sinceEvent = 0
        sinceStir = 0
    }

    /// True while something outside drives the tail (the pointer moving, a click, a key, typing,
    /// a droop changing, and 2 s after): the overlay steps it every display frame then. Otherwise
    /// its motion depends on nothing but time (the idle wave and its own seeded flicks), so the
    /// overlay plays it ahead as a keyframe animation (``advance(frames:dt:pointer:speed:scale:)``)
    /// and the process sleeps between batches.
    var isLively: Bool { animates && sinceStir < 2 }

    /// Steps `frames` frames of `dt` seconds with the pointer still at `pointer` and returns the
    /// tail's path after each (scaled by `scale`): the same frames, step for step, that stepping
    /// it frame by frame gives.
    mutating func advance(frames: Int, dt: Double, pointer: CGPoint, speed: Double, scale: CGFloat) -> [CGPath] {
        var paths: [CGPath] = []
        paths.reserveCapacity(frames)
        for _ in 0..<frames {
            step(dt: dt, pointer: pointer, speed: speed, pointScale: Double(scale))
            paths.append(path(scale: scale))
        }
        return paths
    }

    /// The pointer jumped (a new screen, the first placement): not motion to follow.
    mutating func teleport() {
        lastPointer = nil
        velocity = .zero
        acceleration = .zero
    }

    private mutating func kick(_ amount: Double) {
        guard animates else { return }
        for i in 0..<Self.segmentCount {
            spins[i] += amount * (0.35 + 0.65 * Double(i) / Double(Self.segmentCount - 1))
        }
    }

    // MARK: Stepping

    /// Advances the tail by `dt` seconds of real time while the pointer's tip is at `pointer`
    /// (screen points, y up, any origin). `speed` is ui.animationSpeed: 2 plays twice as fast.
    /// `pointScale` is screen points per design-grid unit (the figure's scale).
    mutating func step(dt: Double, pointer: CGPoint, speed: Double = 1, pointScale: Double = 1.3) {
        guard animates else {
            settleAtRest()
            lastPointer = pointer
            return
        }
        let real = min(max(dt, 0), 0.05)
        let simulated = real * min(max(speed, 0.25), 4)
        let last = lastPointer ?? pointer
        lastPointer = pointer
        guard simulated > 0 else { return }
        // The pointer's velocity and acceleration in design units per simulated second, smoothed
        // so frame jitter does not shake the tail.
        let raw = CGVector(dx: (pointer.x - last.x) / simulated / pointScale, dy: (pointer.y - last.y) / simulated / pointScale)
        let follow = 1 - exp(-simulated / 0.025)
        let next = CGVector(dx: velocity.dx + (raw.dx - velocity.dx) * follow, dy: velocity.dy + (raw.dy - velocity.dy) * follow)
        let rawAcceleration = CGVector(dx: (next.dx - velocity.dx) / simulated, dy: (next.dy - velocity.dy) / simulated)
        let followAcceleration = 1 - exp(-simulated / 0.03)
        acceleration = CGVector(dx: acceleration.dx + (rawAcceleration.dx - acceleration.dx) * followAcceleration,
                                dy: acceleration.dy + (rawAcceleration.dy - acceleration.dy) * followAcceleration)
        velocity = next
        let count = max(1, Int((simulated / tuning.maxSubstep).rounded(.up)))
        let h = simulated / Double(count)
        for _ in 0..<count { substep(h) }
    }

    /// The rest pose, still.
    private mutating func settleAtRest() {
        for i in 0..<Self.segmentCount {
            angles[i] = Self.rest.absolute[i]
            spins[i] = 0
        }
        stretch = 0
        stretchSpeed = 0
        velocity = .zero
        acceleration = .zero
        excitement = 0
    }

    private mutating func substep(_ h: Double) {
        let n = Self.segmentCount
        sinceEvent += h
        sinceStir += h
        if hypot(velocity.dx, velocity.dy) > 2 || abs((drooping ? 1 : 0) - droop) > 0.01 { sinceStir = 0 }
        calm += ((sinceEvent > tuning.calmAfter ? 1 : 0) - calm) * (1 - exp(-h / tuning.calmEase))
        droop += ((drooping ? 1 : 0) - droop) * (1 - exp(-h / tuning.droopEase))
        excitement *= exp(-h / tuning.wiggleDecay)
        let moodRate = (1 - 0.35 * calm) * (1 - 0.5 * droop)
        let moodAmplitude = (1 - 0.25 * calm) * (1 - 0.6 * droop)
        for j in phases.indices {
            phases[j] = (phases[j] + 2 * .pi * rates[j] * moodRate * h).truncatingRemainder(dividingBy: 2 * .pi)
        }
        wigglePhase = (wigglePhase + 2 * .pi * tuning.wiggleFrequency * h).truncatingRemainder(dividingBy: 2 * .pi)
        untilFlick -= h * moodRate
        if untilFlick <= 0 {
            untilFlick = tuning.flickGap.lowerBound + (tuning.flickGap.upperBound - tuning.flickGap.lowerBound) * random.unit()
            kick(tuning.flickKick * (random.unit() < 0.5 ? 1 : -1) * moodAmplitude)
        }
        // The outside force (per unit mass): drag against the pointer's velocity, inertia
        // against its acceleration, each saturating so a fast fling stays bounded.
        let speed = Double(hypot(velocity.dx, velocity.dy))
        let dragScale = tuning.drag / (1 + speed / tuning.dragSaturation)
        let accel = Double(hypot(acceleration.dx, acceleration.dy))
        let inertiaScale = tuning.inertia / (1 + accel / tuning.accelSaturation)
        let fx = -(Double(velocity.dx) * dragScale + Double(acceleration.dx) * inertiaScale)
        let fy = -(Double(velocity.dy) * dragScale + Double(acceleration.dy) * inertiaScale)
        // Stretch on a spring toward a speed-dependent length.
        let stretchBefore = stretch
        let stretchTarget = tuning.stretchMax * speed / (speed + tuning.stretchHalfSpeed)
        stretchSpeed += (-(stretch - stretchTarget) * tuning.stretchSpring - stretchSpeed * tuning.stretchFriction) * h
        stretch = min(max(stretch + stretchSpeed * h, -0.08), 0.25)

        Self.writePoints(angles: angles, stretch: stretch, into: &scratchPoints)
        for i in 0..<n {
            let pose = Self.rest.relative[i] + (Self.droopRelative[i] - Self.rest.relative[i]) * droop
            let along = 0.6 + 0.4 * Double(i) / Double(n - 1)
            var wave = 0.0
            for j in phases.indices {
                wave += tuning.waveAmplitudes[j] * sin(phases[j] - tuning.waveLags[j] * Double(i))
            }
            wave *= along * moodAmplitude
            wave += excitement * tuning.wiggleAmplitude * along * sin(wigglePhase - tuning.wiggleLag * Double(i))
            scratchTarget[i] = pose + wave
        }
        for i in 0..<n {
            let relative = angles[i] - (i > 0 ? angles[i - 1] : 0)
            scratchError[i] = Self.wrap(relative - scratchTarget[i])
        }
        for i in 0..<n {
            let parentSpin = i > 0 ? spins[i - 1] : 0
            var torque = -tuning.jointStiffness[i] * scratchError[i] - damping[i] * (spins[i] - parentSpin)
            if i + 1 < n {
                torque += tuning.jointStiffness[i + 1] * scratchError[i + 1] + damping[i + 1] * (spins[i + 1] - spins[i])
            }
            // The outside force on the chain beyond this joint, about the joint.
            var cx = 0.0, cy = 0.0
            for k in (i + 1)...n {
                cx += Double(scratchPoints[k].x)
                cy += Double(scratchPoints[k].y)
            }
            let beyond = Double(n - i)
            let rx = cx / beyond - Double(scratchPoints[i].x), ry = cy / beyond - Double(scratchPoints[i].y)
            torque += (rx * fy - ry * fx) * beyond / Double(n)
            torque -= tuning.air * spins[i] * tuning.segmentInertia[i]
            scratchTorque[i] = torque / tuning.segmentInertia[i]
        }
        for i in 0..<n {
            scratchAngles[i] = angles[i]
            spins[i] += scratchTorque[i] * h
            angles[i] += spins[i] * h
        }
        // Limits: each joint's bend, then every segment's direction (so a bend never points one
        // into the pointer).
        for i in 1..<n {
            let bend = angles[i] - angles[i - 1] - Self.rest.relative[i]
            if bend > tuning.maxBend {
                angles[i] = angles[i - 1] + Self.rest.relative[i] + tuning.maxBend
                spins[i] = min(spins[i], spins[i - 1])
            } else if bend < -tuning.maxBend {
                angles[i] = angles[i - 1] + Self.rest.relative[i] - tuning.maxBend
                spins[i] = max(spins[i], spins[i - 1])
            }
        }
        for i in 0..<n {
            if angles[i] < tuning.directions.lowerBound {
                angles[i] = tuning.directions.lowerBound
                spins[i] = max(spins[i], 0)
            } else if angles[i] > tuning.directions.upperBound {
                angles[i] = tuning.directions.upperBound
                spins[i] = min(spins[i], 0)
            }
        }
        // Never into the pointer: a step that would put a point inside it is undone, and if the
        // pose it returns to is inside too, the tail eases toward its rest pose (never inside)
        // until it is out.
        if insidePointer() {
            for i in 0..<n {
                angles[i] = scratchAngles[i]
                spins[i] = 0
            }
            stretch = stretchBefore
            stretchSpeed = 0
            var tries = 0
            while insidePointer(), tries < 40 {
                for i in 0..<n { angles[i] += (Self.rest.absolute[i] - angles[i]) * 0.2 }
                stretch *= 0.8
                tries += 1
            }
            if insidePointer() {
                for i in 0..<n { angles[i] = Self.rest.absolute[i] }
                stretch = 0
            }
        }
    }

    private mutating func insidePointer() -> Bool {
        Self.writePoints(angles: angles, stretch: stretch, into: &scratchPoints)
        for k in 1...Self.segmentCount where Self.pointerContains(scratchPoints[k]) { return true }
        return false
    }

    // MARK: Output

    /// The longest the tail can be: its rest length stretched to the limit.
    static var maxLength: Double { rest.lengths.reduce(0, +) * 1.25 }

    /// The chain's points, root first (design grid, y up).
    var points: [CGPoint] {
        var points = Array(repeating: CGPoint.zero, count: Self.segmentCount + 1)
        Self.writePoints(angles: angles, stretch: stretch, into: &points)
        return points
    }

    private static func writePoints(angles: [Double], stretch: Double, into points: inout [CGPoint]) {
        var x = Double(root.x), y = Double(root.y)
        points[0] = root
        let scale = 1 + stretch
        for i in 0..<segmentCount {
            x += cos(angles[i]) * rest.lengths[i] * scale
            y += sin(angles[i]) * rest.lengths[i] * scale
            points[i + 1] = CGPoint(x: x, y: y)
        }
    }

    /// The tail as a smooth curve through the chain's points (a Catmull-Rom spline as cubics),
    /// scaled by `scale` (the figure's design-grid scale). Mutating only to reuse its scratch
    /// points: the path is the one allocation per frame.
    mutating func path(scale: CGFloat) -> CGPath {
        Self.writePoints(angles: angles, stretch: stretch, into: &scratchPoints)
        return Self.spline(through: scratchPoints, scale: scale)
    }

    /// A Catmull-Rom spline through `points` as cubics, with mirrored phantom ends.
    static func spline(through points: [CGPoint], scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first, points.count >= 2 else { return path }
        let n = points.count - 1
        func at(_ k: Int) -> CGPoint {
            if k < 0 { return CGPoint(x: 2 * points[0].x - points[1].x, y: 2 * points[0].y - points[1].y) }
            if k > n { return CGPoint(x: 2 * points[n].x - points[n - 1].x, y: 2 * points[n].y - points[n - 1].y) }
            return points[k]
        }
        path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
        for k in 0..<n {
            let p0 = at(k - 1), p1 = at(k), p2 = at(k + 1), p3 = at(k + 2)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: CGPoint(x: p2.x * scale, y: p2.y * scale),
                          control1: CGPoint(x: c1.x * scale, y: c1.y * scale),
                          control2: CGPoint(x: c2.x * scale, y: c2.y * scale))
        }
        return path
    }

    // MARK: Geometry

    static func pointerContains(_ p: CGPoint) -> Bool {
        var inside = false
        var j = pointerOutline.count - 1
        for i in pointerOutline.indices {
            let a = pointerOutline[i], b = pointerOutline[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func cubic(_ c: [CGPoint], _ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, cc = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * Double(c[0].x) + b * Double(c[1].x) + cc * Double(c[2].x) + d * Double(c[3].x),
                       y: a * Double(c[0].y) + b * Double(c[1].y) + cc * Double(c[2].y) + d * Double(c[3].y))
    }

    /// The rest curve split into equal-length segments.
    private static func restPose() -> (points: [CGPoint], lengths: [Double], absolute: [Double], relative: [Double]) {
        let samples = (0...400).map { cubic(restCurve, Double($0) / 400) }
        var cumulative = [0.0]
        for i in 1..<samples.count {
            cumulative.append(cumulative[i - 1] + Double(hypot(samples[i].x - samples[i - 1].x, samples[i].y - samples[i - 1].y)))
        }
        let total = cumulative[cumulative.count - 1]
        var points: [CGPoint] = []
        var j = 0
        for k in 0...segmentCount {
            let target = total * Double(k) / Double(segmentCount)
            while j < samples.count - 2, cumulative[j + 1] < target { j += 1 }
            let f = (target - cumulative[j]) / max(cumulative[j + 1] - cumulative[j], 1e-9)
            points.append(CGPoint(x: Double(samples[j].x) + Double(samples[j + 1].x - samples[j].x) * f,
                                  y: Double(samples[j].y) + Double(samples[j + 1].y - samples[j].y) * f))
        }
        let lengths = (0..<segmentCount).map { Double(hypot(points[$0 + 1].x - points[$0].x, points[$0 + 1].y - points[$0].y)) }
        let absolute = (0..<segmentCount).map { Double(atan2(points[$0 + 1].y - points[$0].y, points[$0 + 1].x - points[$0].x)) }
        return (points, lengths, absolute, relative(absolute))
    }

    private static func relative(_ absolute: [Double]) -> [Double] {
        absolute.indices.map { $0 == 0 ? absolute[0] : absolute[$0] - absolute[$0 - 1] }
    }

    private static func wrap(_ angle: Double) -> Double {
        var a = (angle + .pi).truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return a - .pi
    }

    /// FNV-1a over the session id's UTF-8: a seed that is the same in every process (Swift's
    /// `hashValue` is not).
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// SplitMix64: a small deterministic random source for the tail's seeded flicks and phases.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

/// When the overlay steps the tail and when it plays it ahead (a pure state machine, so tests can
/// drive it with their own clock).
///
/// The display link calls ``frame(at:pointer:gliding:scale:)`` once per display frame. While
/// something drives the tail (``AgentCursorTail/isLively``), the pointer is gliding, or the frame
/// is the first after the link woke (no time step yet, so no velocity), the tail is stepped and
/// drawn this frame. Otherwise its motion depends only on time: the next `batchFrames` frames are
/// stepped ahead and handed back to play as one keyframe animation while the link sleeps;
/// ``batchEnded(at:scale:)`` hands back the next batch. ``stir(at:scale:_:)`` changes the tail
/// from outside: a running batch first ends exactly where it is on screen (a copy of the batch's
/// start, stepped to now: the same frames the animation showed).
struct AgentCursorTailDriver {
    /// Frames per played-ahead batch and their spacing: half a second at 60 keyframes a second
    /// (the render server interpolates between them at the display's refresh). Short, so making
    /// a batch is a small spike on the main thread (about 0.12 ms on an M4 for the frames and
    /// their shadow outlines, against 0.48 ms for 2 s; AgentCursorTailBenchTests).
    static let batchFrames = 30
    static let batchStep = 1.0 / 60

    enum Output {
        /// Draw this path now; the link keeps running.
        case path(CGPath)
        /// Play these paths, `batchStep` apart, and pause the link until the batch ends. The first
        /// is the pose on screen now; the last is where the model is when the batch ends.
        case batch([CGPath])
    }

    var model: AgentCursorTail
    /// ui.animationSpeed.
    var speed = 1.0
    private(set) var batch: (start: AgentCursorTail, began: Double, pointer: CGPoint)?
    private var lastFrame: Double?

    init(model: AgentCursorTail) { self.model = model }

    var isBatching: Bool { batch != nil }

    /// One display frame at `now` (seconds) with the pointer's tip at `pointer`.
    mutating func frame(at now: Double, pointer: CGPoint, gliding: Bool, scale: CGFloat) -> Output {
        let dt = lastFrame.map { now - $0 } ?? 0
        lastFrame = now
        model.step(dt: dt, pointer: pointer, speed: speed, pointScale: Double(scale))
        // Only a calm tail on a real time step, with the pointer still, may be played ahead.
        if model.animates, dt > 0, !gliding, !model.isLively {
            return .batch(startBatch(at: now, pointer: pointer, scale: scale))
        }
        return .path(model.path(scale: scale))
    }

    /// The running batch has played out: the next one starts from its last frame (the model is
    /// already there).
    mutating func batchEnded(at now: Double, scale: CGFloat) -> [CGPath]? {
        guard let batch else { return nil }
        return startBatch(at: now, pointer: batch.pointer, scale: scale)
    }

    /// Changes the tail from outside. Returns the path to show now when a batch was running (its
    /// animation should go; the link should wake).
    @discardableResult
    mutating func stir(at now: Double, scale: CGFloat, _ change: (inout AgentCursorTail) -> Void) -> CGPath? {
        var shown: CGPath?
        if let batch {
            self.batch = nil
            // Keyframe k shows the pose k steps after the batch's start (keyframe 0 is the start).
            let frames = min(Int((max(now - batch.began, 0) / Self.batchStep).rounded()), Self.batchFrames)
            var copy = batch.start
            for _ in 0..<frames {
                copy.step(dt: Self.batchStep, pointer: batch.pointer, speed: speed, pointScale: Double(scale))
            }
            model = copy
            shown = model.path(scale: scale)
        }
        lastFrame = nil
        change(&model)
        return shown
    }

    /// The link stopped (hidden, no animation): no batch, and the next frame starts a new clock.
    mutating func stop() {
        batch = nil
        lastFrame = nil
    }

    private mutating func startBatch(at now: Double, pointer: CGPoint, scale: CGFloat) -> [CGPath] {
        let start = model
        let now0 = model.path(scale: scale)
        let ahead = model.advance(frames: Self.batchFrames, dt: Self.batchStep, pointer: pointer, speed: speed, scale: scale)
        batch = (start, now, pointer)
        lastFrame = nil
        return [now0] + ahead
    }
}

extension AgentCursorTail {
    /// The white edge's outline (its 5.6 pt stroke as a filled shape), for its shadow.
    static func edgeOutline(_ path: CGPath) -> CGPath {
        path.copy(strokingWithWidth: 5.6, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}
