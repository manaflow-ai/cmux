import Foundation

/// `Particles {choreography}` (`cmux-app-host/js/ABI.md` "Particles choreography (`cmux.particles/1`)"):
/// the player that turns a `cmux.particles/1` document into dot positions at a time. Pure numbers, no
/// views, so it is tested on its own and the drawing (`AppSceneChoreographyGlyph`) only asks it where
/// the dots are. The host's Rust validator (cmux-app-host `src/particles.rs`) refuses an invalid
/// document before it reaches here; the parse below still reads defensively and gives up (nil) on
/// anything it does not understand.
///
/// A port of the web player (`webviews/src/apps/scene/choreography.ts`), with the same numbers and the
/// same rules, so one document looks the same in both renderers:
/// - A frame's `dots` are `[x, y, scale]`, points from the node's centre (+y down); a dot keeps its
///   index across frames and phases, and a dot a frame does not list sits hidden at the centre.
/// - Between two frames the renderer eases by the later frame's `ease`, else the phase's, else linear.
/// - The first phase ever played starts on its first frame. A phase that follows another starts from
///   where the dots are: its first segment eases from the on-screen dots instead of from its frame at 0
///   (a phase whose frames all sit at 0 eases into them over its whole duration).
/// - A generated phase (`sites`, `spawn`, `lifeFrames`) births a dot every `spawn.every` ms at the next
///   site of `order`; each lives `life` ms through `lifeFrames` (`centre`, `site`, or `between`, the
///   midpoint of the two). Repeating itself, it carries its live dots over; after another phase it
///   starts with none alive while the previous dots ease into the centre over the first spawn interval.
/// - What plays: `phase` (that phase, looped) wins over `trigger` (`triggers[trigger]`, else
///   `triggers.cycle`, else the document's first phase looped). A list loops; `{intro, loop}` plays the
///   intro once, then loops `loop`. The trigger is read only when a phase ends: unchanged, the program
///   advances; changed, the dots hand off through the `lone` phase (when the document has one) and the
///   new program starts.
///
/// One difference the platform forces: scene props arrive as ``AppJSON``, whose objects do not keep
/// their key order, so "the document's first phase" (the fallback when neither `phase`, the trigger
/// nor `cycle` names one) is the first phase name in sorted order here, where the web takes the first
/// key as written.
nonisolated struct AppSceneChoreography: Sendable, Equatable {
    /// One dot: points from the glyph's centre (+y down) and its scale over the particle size.
    nonisolated struct Dot: Sendable, Equatable {
        var x: Double
        var y: Double
        var s: Double
    }

    nonisolated struct Point: Sendable, Equatable {
        var x: Double
        var y: Double
    }

    nonisolated enum Ease: Sendable, Equatable {
        case linear
        /// A cubic Bezier from (0, 0) to (1, 1) through (x1, y1) and (x2, y2).
        case bezier(Double, Double, Double, Double)
        /// A closed-form spring run on the segment's own time: `response` (the period, seconds) and
        /// `dampingFraction` of the document.
        case spring(period: Double, damping: Double)
    }

    nonisolated enum Shape: String, Sendable, Equatable {
        case circle, square
    }

    nonisolated struct Frame: Sendable, Equatable {
        var at: Double
        var dots: [Dot]
        var ease: Ease?
    }

    nonisolated struct LifeFrame: Sendable, Equatable {
        nonisolated enum Position: String, Sendable, Equatable {
            case centre, site, between
        }

        var at: Double
        var pos: Position
        var offset: Point
        var s: Double
        var ease: Ease?
    }

    nonisolated struct Generator: Sendable, Equatable {
        var sites: [Point]
        var every: Double
        var order: [Int]
        var life: Double
        var lifeFrames: [LifeFrame]
    }

    nonisolated struct Phase: Sendable, Equatable {
        var name: String
        /// Milliseconds.
        var duration: Double
        var ease: Ease?
        var frames: [Frame]
        var generator: Generator?
    }

    nonisolated struct Program: Sendable, Equatable {
        var intro: [String]
        var loop: [String]
    }

    /// What the node asks to play: a phase by name (looped), or an acpmux tool kind or session state.
    nonisolated struct Request: Sendable, Equatable {
        var phase: String?
        var trigger: String?

        init(phase: String? = nil, trigger: String? = nil) {
            self.phase = phase
            self.trigger = trigger
        }
    }

    var shape: Shape
    /// Points.
    var size: Double
    /// A scene color token or `#RRGGBB[AA]`.
    var color: String
    /// The most dots on screen at once (1 to 16).
    var max: Int
    var phases: [String: Phase]
    var firstPhase: String
    var triggers: [String: Program]

    static let maxDots = 16
    static let hidden = Dot(x: 0, y: 0, s: 0)
    /// The standard ease-in-out curve's control points (the generated phase's gather falls back to it).
    static let easeInOut = Ease.bezier(0.42, 0, 0.58, 1)

    // MARK: Parse

    private nonisolated struct Refused: Error {}

    /// Reads a validated `cmux.particles/1` document, or nil when it is not one.
    init?(json value: AppJSON?) {
        guard let parsed = try? Self.parse(value) else { return nil }
        self = parsed
    }

    init(shape: Shape, size: Double, color: String, max: Int, phases: [String: Phase], firstPhase: String,
         triggers: [String: Program]) {
        self.shape = shape
        self.size = size
        self.color = color
        self.max = max
        self.phases = phases
        self.firstPhase = firstPhase
        self.triggers = triggers
    }

    /// A finite number, or nil for anything else (absent, not a number, NaN or infinite).
    private static func finite(_ value: AppJSON?) -> Double? {
        guard let number = value?.numberValue, number.isFinite else { return nil }
        return number
    }

    /// The curves of the Motion vocabulary (the web's CSS steps), as control points.
    static func namedCurve(_ name: String) -> Ease? {
        switch name {
        case "easeIn": .bezier(0.42, 0, 1, 1)
        case "easeOut": .bezier(0, 0, 0.58, 1)
        case "easeInOut": .bezier(0.42, 0, 0.58, 1)
        case "smooth": .bezier(0.42, 0, 0.58, 1)
        case "snappy": .bezier(0, 0, 0.58, 1)
        default: nil
        }
    }

    /// nil when absent; throws for a value that is not an ease.
    private static func parseEase(_ value: AppJSON?) throws -> Ease? {
        guard let value else { return nil }
        if let name = value.stringValue {
            if name == "linear" { return .linear }
            guard let curve = namedCurve(name) else { throw Refused() }
            return curve
        }
        guard let fields = value.objectValue else { throw Refused() }
        if let list = fields["bezier"]?.arrayValue, list.count == 4 {
            let numbers = list.compactMap { finite($0) }
            if numbers.count == 4 { return .bezier(numbers[0], numbers[1], numbers[2], numbers[3]) }
        }
        if let spring = fields["spring"]?.objectValue, let response = finite(spring["response"]) {
            let damping = finite(spring["dampingFraction"]) ?? 1
            return .spring(period: response, damping: damping)
        }
        throw Refused()
    }

    /// The built-in formations, in units of the particle size (`row`, `pair`, ...).
    static func builtInFormation(_ name: String, size: Double) -> [Dot]? {
        let u = size
        func dot(_ x: Double, _ y: Double, _ s: Double = 1) -> Dot { Dot(x: x * u, y: y * u, s: s) }
        switch name {
        case "row": return [dot(-2.2, 0), dot(0, 0), dot(2.2, 0)]
        case "pair": return [dot(-1.1, 0), dot(1.1, 0)]
        case "triangle": return [dot(0, -1.3), dot(-1.1, 0.65), dot(1.1, 0.65)]
        case "diagonal": return [dot(-1.1, -1.1), dot(1.1, 1.1)]
        case "grid2x2": return [dot(-1.45, -1.45), dot(1.45, -1.45), dot(-1.45, 1.45), dot(1.45, 1.45)]
        case "lone": return [dot(0, 0, 0.7)]
        case "satellites": return [dot(0, 0, 1.2), dot(-2, 0, 0.6), dot(2, 0, 0.6)]
        default: return nil
        }
    }

    private static func parseDots(_ value: AppJSON?) -> [Dot]? {
        guard let list = value?.arrayValue, list.count <= maxDots else { return nil }
        var dots: [Dot] = []
        for entry in list {
            guard let triple = entry.arrayValue, triple.count == 3 else { return nil }
            let numbers = triple.compactMap { finite($0) }
            guard numbers.count == 3 else { return nil }
            dots.append(Dot(x: numbers[0], y: numbers[1], s: Swift.max(0, numbers[2])))
        }
        return dots
    }

    private static func parseProgram(_ value: AppJSON, phases: [String: Phase]) -> Program? {
        func names(_ list: AppJSON?) -> [String]? {
            guard let list = list?.arrayValue else { return nil }
            var out: [String] = []
            for entry in list {
                guard let name = entry.stringValue, phases[name] != nil else { return nil }
                out.append(name)
            }
            return out
        }
        if value.arrayValue != nil {
            guard let loop = names(value), !loop.isEmpty else { return nil }
            return Program(intro: [], loop: loop)
        }
        guard let fields = value.objectValue else { return nil }
        let intro = fields["intro"] == nil ? [] : names(fields["intro"])
        guard let intro, let loop = names(fields["loop"]), !loop.isEmpty else { return nil }
        return Program(intro: intro, loop: loop)
    }

    private static func parse(_ value: AppJSON?) throws -> AppSceneChoreography {
        guard let document = value?.objectValue, document["$schema"]?.stringValue == "cmux.particles/1" else { throw Refused() }
        let particle = document["particle"]?.objectValue ?? [:]
        guard let size = finite(particle["size"]), size > 0 else { throw Refused() }
        let max = finite(particle["max"]).map { Int(Swift.min(Swift.max(($0 + 0.5).rounded(.down), 1), Double(maxDots))) } ?? maxDots
        let formations = document["formations"]?.objectValue ?? [:]
        guard let rawPhases = document["phases"]?.objectValue else { throw Refused() }
        var phases: [String: Phase] = [:]
        for (name, raw) in rawPhases {
            guard let fields = raw.objectValue, let length = finite(fields["duration"]), length > 0 else { throw Refused() }
            let ease = try parseEase(fields["ease"])
            var frames: [Frame] = []
            if let rawFrames = fields["frames"] {
                guard let list = rawFrames.arrayValue else { throw Refused() }
                for entry in list {
                    guard let frame = entry.objectValue, let at = finite(frame["at"]) else { throw Refused() }
                    let frameEase = try parseEase(frame["ease"])
                    let dots: [Dot]?
                    if let formation = frame["formation"]?.stringValue {
                        dots = formations[formation] != nil ? parseDots(formations[formation]) : builtInFormation(formation, size: size)
                    } else {
                        dots = parseDots(frame["dots"])
                    }
                    guard let dots else { throw Refused() }
                    frames.append(Frame(at: at, dots: Array(dots.prefix(max)), ease: frameEase))
                }
            }
            var generator: Generator?
            if fields["spawn"] != nil || fields["sites"] != nil || fields["lifeFrames"] != nil {
                guard let spawn = fields["spawn"]?.objectValue, let rawSites = fields["sites"]?.arrayValue,
                      let rawLife = fields["lifeFrames"]?.arrayValue, let every = finite(spawn["every"]),
                      let life = finite(spawn["life"]), let rawOrder = spawn["order"]?.arrayValue else { throw Refused() }
                var sites: [Point] = []
                for entry in rawSites {
                    guard let pair = entry.arrayValue, pair.count == 2 else { throw Refused() }
                    let numbers = pair.compactMap { finite($0) }
                    guard numbers.count == 2 else { throw Refused() }
                    sites.append(Point(x: numbers[0], y: numbers[1]))
                }
                guard !sites.isEmpty else { throw Refused() }
                var order: [Int] = []
                for entry in rawOrder {
                    // A site index: a whole number below the site count (a fraction indexes nothing).
                    guard let index = finite(entry), index >= 0, index < Double(sites.count), index.rounded(.down) == index else { throw Refused() }
                    order.append(Int(index))
                }
                guard !order.isEmpty else { throw Refused() }
                var lifeFrames: [LifeFrame] = []
                for entry in rawLife {
                    guard let frame = entry.objectValue, let at = finite(frame["at"]), let s = finite(frame["s"]),
                          let pos = frame["pos"]?.stringValue.flatMap(LifeFrame.Position.init(rawValue:)) else { throw Refused() }
                    var offset = Point(x: 0, y: 0)
                    if let pair = frame["offset"]?.arrayValue, pair.count == 2 {
                        let numbers = pair.compactMap { finite($0) }
                        if numbers.count == 2 { offset = Point(x: numbers[0], y: numbers[1]) }
                    }
                    let lifeEase = try parseEase(frame["ease"])
                    lifeFrames.append(LifeFrame(at: at, pos: pos, offset: offset, s: s, ease: lifeEase))
                }
                guard !lifeFrames.isEmpty, every > 0 else { throw Refused() }
                generator = Generator(sites: sites, every: every, order: order, life: life, lifeFrames: lifeFrames)
            }
            guard !frames.isEmpty || generator != nil else { throw Refused() }
            phases[name] = Phase(name: name, duration: length, ease: ease, frames: frames, generator: generator)
        }
        guard let firstPhase = phases.keys.sorted().first else { throw Refused() }
        var triggers: [String: Program] = [:]
        if let rawTriggers = document["triggers"]?.objectValue {
            for (kind, raw) in rawTriggers {
                guard let program = parseProgram(raw, phases: phases) else { throw Refused() }
                triggers[kind] = program
            }
        }
        return AppSceneChoreography(
            shape: particle["shape"]?.stringValue == "square" ? .square : .circle,
            size: size,
            color: particle["color"]?.stringValue ?? "accent",
            max: max,
            phases: phases,
            firstPhase: firstPhase,
            triggers: triggers)
    }

    // MARK: Easing

    /// One axis of a cubic Bezier from (0, 0) to (1, 1) with control values `a` and `b`.
    private static func cubic(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private static func bezierAt(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        // Solve x(t) = x by bisection (monotonic in t because x1 and x2 are in [0, 1]); 24 steps is far
        // below a hundredth of a point at glyph sizes.
        var low = 0.0
        var high = 1.0
        var t = x
        for _ in 0..<24 {
            let value = cubic(x1, x2, t)
            if abs(value - x) < 1e-6 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return cubic(y1, y2, t)
    }

    private static func springAt(response: Double, damping: Double, seconds: Double) -> Double {
        if seconds <= 0 { return 0 }
        let w = 2 * Double.pi / Swift.max(response, 0.001)
        let z = Swift.min(Swift.max(damping, 0), 1)
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot()
            return 1 - exp(-z * w * seconds) * (cos(wd * seconds) + (z * w / wd) * sin(wd * seconds))
        }
        return 1 - exp(-w * seconds) * (1 + w * seconds)
    }

    /// Progress (0 to 1, a spring may overshoot) `u` of the way through a segment `segmentMs` long.
    static func easeProgress(_ ease: Ease?, _ u: Double, segmentMs: Double) -> Double {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        switch ease {
        case nil, .linear?: return u
        case .bezier(let x1, let y1, let x2, let y2)?: return bezierAt(x1, y1, x2, y2, u)
        case .spring(let response, let damping)?: return springAt(response: response, damping: damping, seconds: u * segmentMs / 1000)
        }
    }

    private static func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }

    private static func mixDots(_ from: [Dot], _ to: [Dot], _ p: Double) -> [Dot] {
        let count = Swift.max(from.count, to.count)
        var dots: [Dot] = []
        dots.reserveCapacity(count)
        for index in 0..<count {
            let a = index < from.count ? from[index] : hidden
            let b = index < to.count ? to[index] : hidden
            dots.append(Dot(x: mix(a.x, b.x, p), y: mix(a.y, b.y, p), s: Swift.max(0, mix(a.s, b.s, p))))
        }
        return dots
    }

    // MARK: Sampling one phase

    private static func keyframes(_ phase: Phase, from: [Dot]?) -> [Frame] {
        guard let from else { return phase.frames }
        var keys = [Frame(at: 0, dots: from, ease: nil)] + phase.frames.filter { $0.at > 0 }
        if keys.count == 1, let last = phase.frames.last {
            keys.append(Frame(at: 1, dots: last.dots, ease: last.ease))
        }
        return keys
    }

    private static func sampleKeys(_ keys: [Frame], _ phase: Phase, _ p: Double) -> [Dot] {
        guard let first = keys.first else { return [] }
        if p <= first.at { return first.dots }
        for index in keys.indices.dropFirst() {
            let next = keys[index]
            if p <= next.at {
                let prev = keys[index - 1]
                let span = next.at - prev.at
                let u = span > 0 ? (p - prev.at) / span : 1
                return mixDots(prev.dots, next.dots, easeProgress(next.ease ?? phase.ease, u, segmentMs: span * phase.duration))
            }
        }
        return keys[keys.count - 1].dots
    }

    private static func lifeDot(_ generator: Generator, _ phase: Phase, spawn: Int, age: Double) -> Dot {
        let frames = generator.lifeFrames
        let count = generator.order.count
        let site = generator.sites[generator.order[((spawn % count) + count) % count]]
        func place(_ frame: LifeFrame) -> Dot {
            let base: Point = switch frame.pos {
            case .centre: Point(x: 0, y: 0)
            case .site: site
            case .between: Point(x: site.x / 2, y: site.y / 2)
            }
            return Dot(x: base.x + frame.offset.x, y: base.y + frame.offset.y, s: frame.s)
        }
        let p = age / generator.life
        if p <= frames[0].at { return place(frames[0]) }
        for index in frames.indices.dropFirst() {
            let next = frames[index]
            if p <= next.at {
                let prev = frames[index - 1]
                let span = next.at - prev.at
                let u = span > 0 ? (p - prev.at) / span : 1
                let eased = easeProgress(next.ease ?? phase.ease, u, segmentMs: span * generator.life)
                return mixDots([place(prev)], [place(next)], eased)[0]
            }
        }
        return place(frames[frames.count - 1])
    }

    private func sampleGenerated(_ phase: Phase, _ generator: Generator, ms: Double, from: [Dot]?, carry: Bool) -> [Dot] {
        var dots: [Dot] = []
        // Spawns alive now: born at n * every, alive for `life`. Carrying over (the phase repeating
        // itself), spawns from before this pass count as if the phase had been playing all along.
        let first = carry ? ((ms - generator.life) / generator.every).rounded(.down) + 1 : 0
        let last = (ms / generator.every).rounded(.down)
        // Spawns before this pass are the previous pass's, which used the order from its own start.
        let passSpawns = Swift.max(1, (phase.duration / generator.every + 0.5).rounded(.down))
        var spawn = first
        // A validated document has at most `ceil(life / every)` (16) spawns alive; the step cap only
        // keeps a document past the validator from spinning.
        var steps = 0
        while spawn <= last, dots.count < max, steps < 4096 {
            defer { spawn += 1; steps += 1 }
            let age = ms - spawn * generator.every
            if age < 0 || age >= generator.life { continue }
            let index = spawn >= 0 ? spawn : spawn + passSpawns * (-spawn / passSpawns).rounded(.up)
            let wrapped = Int(index.truncatingRemainder(dividingBy: Double(generator.order.count)))
            dots.append(Self.lifeDot(generator, phase, spawn: wrapped, age: age))
        }
        if let from, !carry, ms < generator.every {
            let p = Self.easeProgress(phase.ease ?? Self.easeInOut, ms / generator.every, segmentMs: generator.every)
            for dot in Self.mixDots(from, [], p) where dots.count < max && dot.s > 0 { dots.append(dot) }
        }
        return dots
    }

    /// Where the dots of `phase` are `ms` into it. `from` is where the previous phase left them (nil on
    /// the first phase played); `carry` is true when the phase repeats itself.
    func samplePhase(_ phase: Phase, ms: Double, from: [Dot]?, carry: Bool = false) -> [Dot] {
        let clamped = Swift.min(Swift.max(ms, 0), phase.duration)
        if let generator = phase.generator { return sampleGenerated(phase, generator, ms: clamped, from: from, carry: carry) }
        return Array(Self.sampleKeys(Self.keyframes(phase, from: from), phase, clamped / phase.duration).prefix(max))
    }

    // MARK: The player

    /// What a request plays: its key (a changed key hands off) and the program.
    func program(for request: Request) -> (key: String, program: Program) {
        if let phase = request.phase, !phase.isEmpty, phases[phase] != nil {
            return ("phase:\(phase)", Program(intro: [], loop: [phase]))
        }
        let trigger = request.trigger.flatMap { !$0.isEmpty && triggers[$0] != nil ? $0 : nil } ?? "cycle"
        if let program = triggers[trigger] { return ("trigger:\(trigger)", program) }
        return ("first", Program(intro: [], loop: [firstPhase]))
    }

    /// The phase at position `index` of a program (intro first, then the loop forever).
    static func programPhase(_ program: Program, _ index: Int) -> String {
        if index < program.intro.count { return program.intro[index] }
        return program.loop[(index - program.intro.count) % program.loop.count]
    }

    /// The longest stall the player catches up phase by phase; past it, it restarts the program.
    static let maxCatchUpMs: Double = 60_000

    /// Plays a document: `sample(now)` gives the dots at `now` (ms, the caller's clock), advancing
    /// phases as they end.
    nonisolated struct Player: Sendable {
        let choreography: AppSceneChoreography
        private var request: Request
        private var key: String
        private var program: Program
        private var index = 0
        private var phase: Phase
        private var start: Double
        private var from: [Dot]?
        private var carry = false
        /// After a hand-off through `lone`, the program that starts next.
        private var pending: (key: String, program: Program)?

        init(_ choreography: AppSceneChoreography, request: Request, now: Double) {
            self.choreography = choreography
            self.request = request
            let next = choreography.program(for: request)
            key = next.key
            program = next.program
            phase = choreography.phase(AppSceneChoreography.programPhase(next.program, 0))
            start = now
        }

        /// What the node asks for now; read only when the playing phase ends.
        mutating func setRequest(_ request: Request) {
            self.request = request
        }

        /// The phase playing at the last `sample` and when it started (ms, the caller's clock).
        var current: (phase: String, start: Double) { (phase.name, start) }

        /// The dots to draw at `now` (ms, the same clock as the initializer's), advancing phases as they end.
        mutating func sample(_ now: Double) -> [Dot] {
            if now - start > AppSceneChoreography.maxCatchUpMs { restart(now) }
            while now - start >= phase.duration { advance() }
            return choreography.samplePhase(phase, ms: now - start, from: from, carry: carry)
        }

        /// The still drawn when motion is off or reduced: the first frame of what would play.
        func still() -> [Dot] {
            let next = choreography.program(for: request)
            let first = choreography.phase(AppSceneChoreography.programPhase(next.program, 0))
            return choreography.samplePhase(first, ms: 0, from: nil, carry: false)
        }

        private mutating func restart(_ now: Double) {
            let next = choreography.program(for: request)
            key = next.key
            program = next.program
            index = 0
            pending = nil
            phase = choreography.phase(AppSceneChoreography.programPhase(program, 0))
            start = now
            from = nil
            carry = false
        }

        private mutating func advance() {
            let ended = phase
            let end = start + ended.duration
            let left = choreography.samplePhase(ended, ms: ended.duration, from: from, carry: carry)
            let name: String
            let next = choreography.program(for: request)
            if pending != nil {
                // The hand-off dot played; the waiting program starts (with the newest request).
                key = next.key
                program = next.program
                index = 0
                pending = nil
                name = AppSceneChoreography.programPhase(program, 0)
            } else if next.key == key {
                index += 1
                // Keep the index bounded: past the intro the loop repeats.
                let loopLength = program.loop.count
                if index >= program.intro.count + loopLength { index -= loopLength }
                name = AppSceneChoreography.programPhase(program, index)
            } else if choreography.phases["lone"] != nil, ended.name != "lone",
                      AppSceneChoreography.programPhase(next.program, 0) != "lone" {
                pending = next
                name = "lone"
            } else {
                key = next.key
                program = next.program
                index = 0
                name = AppSceneChoreography.programPhase(program, 0)
            }
            let following = choreography.phase(name)
            carry = following.name == ended.name
            from = left
            phase = following
            start = end
        }
    }

    /// The phase named `name`: every program names only phases of the document (the parse checks
    /// it), so a missing one is the first phase rather than a crash.
    func phase(_ name: String) -> Phase {
        phases[name] ?? phases[firstPhase] ?? Phase(name: name, duration: 1, ease: nil, frames: [Frame(at: 0, dots: [], ease: nil)])
    }
}
