public import AppKit
public import QuartzCore
public import CmuxNextDesignTokens

/// The hooks the Motion gate calls as an animation starts and ends. Each one returns at its first line
/// unless an inspector inspects (``MotionInspector/isActive``), so the gate pays one Bool read per
/// animation while nobody inspects, and nothing per frame.
extension MotionInspector {
    /// The gate entry point an animation started from: its call site and its category.
    struct CallSite {
        var file: StaticString
        var line: UInt
        var category: MotionCategory?

        var text: String { "\(file):\(line)" }
    }

    /// The key a gate-made `CAAnimation` carries while an inspector inspects: its record's id, so a scan
    /// tells the gate's animations from the ones no gate made.
    public static let tagKey = "cmuxMotionRecord"

    /// Runs `body` as the gate entry point at `file`:`line` of `category`: the animations it starts are
    /// recorded with that owner. Only `body` runs while nobody inspects.
    @inline(__always)
    static func within<T>(_ category: MotionCategory?, _ file: StaticString, _ line: UInt, _ body: () throws -> T) rethrows -> T {
        guard let inspector = active else { return try body() }
        let saved = inspector.site
        inspector.site = CallSite(file: file, line: line, category: category)
        defer { inspector.site = saved }
        return try body()
    }

    // MARK: Core Animation

    /// A `CAAnimation` a gate helper made, about to be added (`layer`, when the helper knows it), starting
    /// `delay` seconds from now: tagged and recorded. Returns `animation`.
    @discardableResult
    static func noteAnimation<Kind: CAAnimation>(_ animation: Kind, kind: @autoclosure () -> String? = nil, on layer: CALayer? = nil,
                                                  after delay: CFTimeInterval = 0) -> Kind {
        guard let inspector = active else { return animation }
        let began = CACurrentMediaTime()
        let property = (animation as? CAPropertyAnimation)?.keyPath ?? (animation as? CATransition).map { "transition.\($0.type.rawValue)" } ?? "?"
        let curve = inspector.curve(of: animation)
        let start = inspector.motionNow + delay
        let id = inspector.add(kind: kind() ?? Self.kind(of: animation, property: property, curve: curve), property: property,
                               from: Self.describe((animation as? CABasicAnimation)?.fromValue, additive: animation.isAdditiveValue),
                               to: Self.describe((animation as? CABasicAnimation)?.toValue, additive: animation.isAdditiveValue),
                               curve: curve, runs: .renderServer, ownerType: layer.map(Self.ownerType(of:)), start: start,
                               end: curve.seconds.map { _ in start + MotionActivity.activeSeconds(animation) })
        animation.setValue(NSNumber(value: id), forKey: tagKey)
        inspector.overhead.addNote((CACurrentMediaTime() - began) * 1000)
        return animation
    }

    // MARK: AppKit, transactions, clocks

    /// An `animator()` change AppKit steps on the main thread (an `NSAnimationContext` group) of `view`,
    /// on `curve`. Returns `completion` wrapped to end the record, or `completion` while nobody inspects.
    static func noteAppKit(_ kind: @autoclosure () -> String, view: NSView?, curve: @autoclosure () -> MotionInspectorRecord.Curve,
                           completion: (@MainActor @Sendable () -> Void)?) -> (@MainActor @Sendable () -> Void)? {
        guard let inspector = active else { return completion }
        let began = CACurrentMediaTime()
        let start = inspector.motionNow
        let id = inspector.add(kind: kind(), property: "animator()", from: nil, to: nil, curve: curve(), runs: .appKit,
                               ownerType: view.map { String(describing: type(of: $0)) }, start: start, end: nil)
        inspector.overhead.addNote((CACurrentMediaTime() - began) * 1000)
        return { [weak inspector] in
            inspector?.end(id)
            completion?()
        }
    }

    /// A gate transaction whose implicit layer actions run `seconds` on the render server.
    static func noteTransaction(_ kind: @autoclosure () -> String, seconds: TimeInterval) {
        guard let inspector = active, seconds > 0 else { return }
        let began = CACurrentMediaTime()
        let start = inspector.motionNow
        _ = inspector.add(kind: kind(), property: "implicit", from: nil, to: nil, curve: .timed(seconds: seconds, name: "easeOut"),
                          runs: .renderServer, ownerType: nil, start: start, end: start + seconds)
        inspector.overhead.addNote((CACurrentMediaTime() - began) * 1000)
    }

    /// A CPU spring animator ``MotionClock`` steps from now (`trace`: its span name). Returns its record id.
    static func noteClockRun(_ animator: AnyObject, trace: @autoclosure () -> String) -> UInt64? {
        guard let inspector = active else { return nil }
        return inspector.add(kind: "clock.\(trace())", property: "frame", from: nil, to: nil, curve: .stepped, runs: .main,
                             ownerType: String(describing: type(of: animator)), start: inspector.motionNow, end: nil)
    }

    /// One main-thread step of a clock animator's record: `milliseconds` of work.
    static func noteClockStep(_ id: UInt64?, milliseconds: Double) {
        guard let id, let inspector = active, let index = inspector.records.lastIndex(where: { $0.id == id }) else { return }
        var record = inspector.records[index]
        record.mainFrames += 1
        record.mainTotalMs += milliseconds
        record.mainMaxMs = max(record.mainMaxMs, milliseconds)
        inspector.setCounters { $0[index] = record }
    }

    /// The record `id` ended now.
    static func noteEnded(_ id: UInt64?) {
        guard let id else { return }
        active?.end(id)
    }

    // MARK: Records

    func add(kind: String, property: String, from: String?, to: String?, curve: MotionInspectorRecord.Curve,
             runs: MotionInspectorRecord.Runs, ownerType: String?, start: Double, end: Double?) -> UInt64 {
        retimeNewWindows()
        let site = self.site
        let wall = now()
        // One call site's starts of one kind in one turn (within a millisecond of wall time) are one animation of
        // several layers: a Cmd-N burst stays one row per insert, however many rows it moves.
        if let last = records.indices.last, wall - lastAddWall < 0.001, records[last].site == site?.text, records[last].kind == kind,
           records[last].property == property, records[last].isRunning {
            records[last].layers += 1
            if let end { records[last].expectedEnd = max(records[last].expectedEnd ?? end, end) }
            lastAddWall = wall
            return records[last].id
        }
        lastAddWall = wall
        nextID &+= 1
        records.append(MotionInspectorRecord(id: nextID, site: site?.text, ownerType: ownerType, category: site?.category, kind: kind,
                                             property: property, from: from, to: to, curve: curve, runs: runs, gated: true,
                                             start: start, expectedEnd: end))
        if records.count > Self.endedKept + Self.loopsKept + 64 { records = Self.pruned(records) }
        runningChanged()
        return nextID
    }

    func end(_ id: UInt64) {
        guard let index = records.lastIndex(where: { $0.id == id }), records[index].ended == nil else { return }
        records[index].ended = motionNow
    }

    // MARK: Describing animations

    /// The curve of a `CAAnimation`: a spring's response and damping (mass-1 stiffness and damping back
    /// to SwiftUI terms), a timed curve's duration and timing function, a loop's period.
    func curve(of animation: CAAnimation) -> MotionInspectorRecord.Curve {
        let repeats = animation.repeatCount == .infinity || animation.repeatDuration == .infinity || animation.repeatCount > 1e6
        if repeats { return .loop(period: animation.duration * (animation.autoreverses ? 2 : 1)) }
        if let spring = animation as? CASpringAnimation, spring.stiffness > 0 {
            let omega = (spring.stiffness / max(spring.mass, .ulpOfOne)).squareRoot()
            let parameters = SpringParameters(response: 2 * .pi / omega,
                                              dampingFraction: spring.damping / (2 * (spring.stiffness * spring.mass).squareRoot()))
            return .spring(response: parameters.response, damping: parameters.dampingFraction,
                           perceived: perceived(parameters, ending: spring.duration))
        }
        let name: String
        switch animation {
        case let keyframes as CAKeyframeAnimation: name = "keyframes(\(keyframes.values?.count ?? 0))"
        case let transition as CATransition: name = "transition.\(transition.type.rawValue)"
        case is CAAnimationGroup: name = "group"
        default: name = Self.timingName(animation.timingFunction)
        }
        return .timed(seconds: animation.duration, name: name)
    }

    /// A spring's perceived duration (``SpringParameters/perceivedDuration``, cached: it simulates), at most
    /// `duration` when the animation is cut there.
    private func perceived(_ parameters: SpringParameters, ending duration: CFTimeInterval) -> Double {
        let key = SpringKey(response: parameters.response, damping: parameters.dampingFraction)
        let value = perceivedCache[key] ?? {
            let solved = parameters.perceivedDuration
            if perceivedCache.count < 256 { perceivedCache[key] = solved }
            return solved
        }()
        return duration > 0 ? min(value, duration) : value
    }

    struct SpringKey: Hashable {
        var response: Double
        var damping: Double
    }

    static func timingName(_ function: CAMediaTimingFunction?) -> String {
        guard let function else { return "linear" }
        var points: [Float] = []
        for index in 1...2 {
            var values: [Float] = [0, 0]
            // SAFETY: getControlPoint writes the point's two Floats into the two-element array, lent for the call.
            unsafe function.getControlPoint(at: index, values: &values)
            points += values
        }
        switch points {
        case [0, 0, 0.58, 1]: return "easeOut"
        case [0.42, 0, 1, 1]: return "easeIn"
        case [0.42, 0, 0.58, 1]: return "easeInEaseOut"
        case [0, 0, 1, 1]: return "linear"
        default: return "cubic(" + points.map { String(format: "%.2f", $0) }.joined(separator: ",") + ")"
        }
    }

    static func kind(of animation: CAAnimation, property: String, curve: MotionInspectorRecord.Curve) -> String {
        switch animation {
        case is CASpringAnimation: "spring.\(property)"
        case is CAKeyframeAnimation: "keyframes.\(property)"
        case is CATransition: property
        default: curve.seconds == nil ? "loop.\(property)" : "timed.\(property)"
        }
    }

    /// A short text for an animation value: numbers, points, sizes and rects; "color" for a color.
    static func describe(_ value: Any?, additive: Bool) -> String? {
        guard let value else { return nil }
        // An additive animation's values are offsets from the model value.
        let prefix = additive ? "Δ" : ""
        func n(_ v: CGFloat) -> String { String(format: "%.4g", Double(v)) }
        switch value {
        case let number as NSNumber: return prefix + String(format: "%.4g", number.doubleValue)
        case let value as NSValue:
            let type = String(cString: value.objCType)
            if type.hasPrefix("{CGPoint") { let p = value.pointValue; return prefix + "(\(n(p.x)), \(n(p.y)))" }
            if type.hasPrefix("{CGSize") { let s = value.sizeValue; return prefix + "\(n(s.width))x\(n(s.height))" }
            if type.hasPrefix("{CGRect") { let r = value.rectValue; return prefix + "(\(n(r.minX)), \(n(r.minY)) \(n(r.width))x\(n(r.height)))" }
            if type.hasPrefix("{CATransform3D") { return prefix + "transform" }
            return prefix + type
        default:
            if CFGetTypeID(value as CFTypeRef) == CGColor.typeID { return "color" }
            return String(describing: type(of: value))
        }
    }

    /// The type that owns `layer`: its delegate's (a view), else the layer's own class.
    static func ownerType(of layer: CALayer) -> String {
        if let delegate = layer.delegate { return String(describing: type(of: delegate)) }
        return String(describing: type(of: layer))
    }
}

private extension CAAnimation {
    var isAdditiveValue: Bool { (self as? CAPropertyAnimation)?.isAdditive ?? false }
}
