public import QuartzCore

extension MotionGate {
    /// A looping tour of the agent cursor through `stops` (layer positions), for an illustration
    /// such as the first-run Computer Use page: it glides to each stop, rests there for a beat and
    /// moves on, then glides back to the first. One stop takes one `breath` period; nil when loops
    /// are off (the master switch, the category's switch, animation speed off or Reduce Motion),
    /// so the cursor stays at its rest position and the picture still reads.
    public func cursorTourAnimation(stops: [CGPoint]) -> CAAnimation? {
        guard stops.count >= 2, let period = period(.breath) else { return nil }
        let tour = CAKeyframeAnimation(keyPath: "position")
        // Each stop: arrive (glide, 55% of the stop) and rest (45%); the last glide returns to the first.
        var values: [NSValue] = []
        var times: [NSNumber] = []
        let count = Double(stops.count)
        for (index, stop) in stops.enumerated() {
            let start = Double(index) / count
            values.append(NSValue(point: stop))
            times.append(NSNumber(value: start + 0.55 / count))
            values.append(NSValue(point: stop))
            times.append(NSNumber(value: start + 1 / count - 0.0001))
        }
        // The first glide starts where the loop ends (the last stop), so the loop has no jump.
        values.insert(NSValue(point: stops[stops.count - 1]), at: 0)
        times.insert(0, at: 0)
        tour.values = values
        tour.keyTimes = times
        tour.calculationMode = .linear
        tour.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
        tour.duration = period * count
        tour.repeatCount = .infinity
        tour.isRemovedOnCompletion = false
        return tour
    }

    /// The click ring at a cursor tour's stops: it grows and fades once at each arrival; nil when
    /// loops are off. `stops` is the tour's count of stops, `period` matches the tour.
    public func cursorTourClickAnimation(stops: Int) -> CAAnimation? {
        guard stops >= 2, let period = period(.breath) else { return nil }
        let count = Double(stops)
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        var values: [Float] = [0]
        var times: [Double] = [0]
        for index in 0..<stops {
            let arrive = (Double(index) + 0.55) / count
            values += [0, 0.9, 0]
            times += [arrive - 0.0001, arrive, min(arrive + 0.3 / count, 1)]
        }
        pulse.values = values.map(NSNumber.init(value:))
        pulse.keyTimes = times.map(NSNumber.init(value:))
        pulse.duration = period * count
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        return pulse
    }
}
