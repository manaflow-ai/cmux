import CmuxSimulator

struct SimulatorInputStateMachine {
    typealias ScrollPhase = SimulatorScrollPhase

    private(set) var activePointer: SimulatorPoint?
    private(set) var activeEdge: SimulatorEdge = .none
    private(set) var usesSecondaryTouch = false
    private(set) var heldKeys: Set<UInt32> = []
    private var scrollPoint: SimulatorPoint?
    private var scrollAnchor: SimulatorPoint?
    private var secondaryTouchOffset: SimulatorInputDelta?
    private var orientationGeometry: SimulatorOrientationGeometry?

    mutating func updateOrientationGeometry(_ geometry: SimulatorOrientationGeometry?) {
        orientationGeometry = geometry
    }

    mutating func pointerBegan(
        at point: SimulatorPoint,
        optionPinch: Bool,
        parallelPan: Bool = false,
        edge: SimulatorEdge? = nil
    ) -> [SimulatorWorkerInbound] {
        var messages = releasePointerIfNeeded()
        messages.append(contentsOf: releaseScrollIfNeeded())
        activePointer = point
        activeEdge = edge ?? simulatorEdge(at: point)
        usesSecondaryTouch = optionPinch
        secondaryTouchOffset = optionPinch && parallelPan
            ? SimulatorInputDelta(x: 1 - (2 * point.x), y: 1 - (2 * point.y))
            : nil
        messages.append(pointer(.began, at: point))
        return messages
    }

    mutating func pointerMoved(to point: SimulatorPoint) -> [SimulatorWorkerInbound] {
        guard activePointer != nil else { return [] }
        activePointer = point
        return [pointer(.moved, at: point)]
    }

    mutating func pointerEnded(at point: SimulatorPoint, cancelled: Bool = false) -> [SimulatorWorkerInbound] {
        guard activePointer != nil else { return [] }
        let message = pointer(cancelled ? .cancelled : .ended, at: point)
        activePointer = nil
        activeEdge = .none
        usesSecondaryTouch = false
        secondaryTouchOffset = nil
        return [message]
    }

    mutating func key(usage: UInt32, phase: SimulatorKeyPhase) -> [SimulatorWorkerInbound] {
        switch phase {
        case .down:
            heldKeys.insert(usage)
            return [.key(SimulatorKeyEvent(usage: usage, phase: .down))]
        case .up:
            guard heldKeys.remove(usage) != nil else { return [] }
            return [.key(SimulatorKeyEvent(usage: usage, phase: .up))]
        }
    }

    mutating func scroll(
        deltaX: Double,
        deltaY: Double,
        phase: ScrollPhase,
        anchor: SimulatorPoint = SimulatorPoint(x: 0.5, y: 0.5)
    ) -> [SimulatorWorkerInbound] {
        guard activePointer == nil else { return [] }
        switch phase {
        case .discrete:
            let origin = clampedScrollAnchor(anchor)
            let destination = scrolledPoint(from: origin, deltaX: deltaX, deltaY: deltaY)
            let rawOrigin = rawScrollPoint(origin)
            let rawDestination = rawScrollPoint(destination)
            return [.scrollWheel(SimulatorScrollWheelEvent(
                anchor: rawOrigin,
                deltaX: rawDestination.x - rawOrigin.x,
                deltaY: rawDestination.y - rawOrigin.y
            ))]
        case .began:
            var messages = releaseScrollIfNeeded()
            let origin = clampedScrollAnchor(anchor)
            let destination = scrolledPoint(from: origin, deltaX: deltaX, deltaY: deltaY)
            scrollAnchor = origin
            scrollPoint = destination
            messages.append(contentsOf: [
                scrollPointer(.began, at: origin),
                scrollPointer(.moved, at: destination),
            ])
            return messages
        case .changed:
            let origin = scrollPoint ?? clampedScrollAnchor(anchor)
            let unclamped = unboundedScrolledPoint(from: origin, deltaX: deltaX, deltaY: deltaY)
            var messages: [SimulatorWorkerInbound] = []
            if scrollPoint == nil {
                scrollAnchor = origin
                messages.append(scrollPointer(.began, at: origin))
            } else if isOutsideScrollBounds(unclamped) {
                messages.append(scrollPointer(.ended, at: origin))
                let restart = scrollAnchor ?? clampedScrollAnchor(anchor)
                messages.append(scrollPointer(.began, at: restart))
                let destination = scrolledPoint(
                    from: restart,
                    deltaX: deltaX,
                    deltaY: deltaY
                )
                scrollPoint = destination
                messages.append(scrollPointer(.moved, at: destination))
                return messages
            }
            let destination = clampedScrollPoint(unclamped)
            scrollPoint = destination
            messages.append(scrollPointer(.moved, at: destination))
            return messages
        case .ended, .cancelled:
            guard let scrollPoint else { return [] }
            self.scrollPoint = nil
            scrollAnchor = nil
            return [scrollPointer(phase == .cancelled ? .cancelled : .ended, at: scrollPoint)]
        }
    }

    mutating func releaseAll() -> [SimulatorWorkerInbound] {
        var messages = releasePointerIfNeeded()
        messages.append(contentsOf: releaseScrollIfNeeded())
        for usage in heldKeys.sorted() {
            messages.append(.key(SimulatorKeyEvent(usage: usage, phase: .up)))
        }
        heldKeys.removeAll(keepingCapacity: true)
        messages.append(.releaseInputs)
        return messages
    }

    private func pointer(_ phase: SimulatorTouchPhase, at point: SimulatorPoint) -> SimulatorWorkerInbound {
        let points = touchPoints(for: point)
        let event = SimulatorPointerEvent(
            phase: phase,
            primary: points.primary,
            secondary: points.secondary,
            edge: activeEdge
        )
        return .pointer(orientationGeometry?.rawPointerEvent(event) ?? event)
    }

    private mutating func releasePointerIfNeeded() -> [SimulatorWorkerInbound] {
        guard let activePointer else { return [] }
        let message = pointer(.cancelled, at: activePointer)
        self.activePointer = nil
        activeEdge = .none
        usesSecondaryTouch = false
        secondaryTouchOffset = nil
        return [message]
    }

    private mutating func releaseScrollIfNeeded() -> [SimulatorWorkerInbound] {
        guard let scrollPoint else { return [] }
        let message = scrollPointer(.cancelled, at: scrollPoint)
        self.scrollPoint = nil
        scrollAnchor = nil
        return [message]
    }

    private func touchPoints(for point: SimulatorPoint) -> (
        primary: SimulatorPoint,
        secondary: SimulatorPoint?
    ) {
        guard usesSecondaryTouch else { return (point, nil) }
        if let offset = secondaryTouchOffset {
            let secondary = SimulatorInputDelta(x: point.x + offset.x, y: point.y + offset.y)
            let correctionX = secondary.x < 0 ? -secondary.x : (secondary.x > 1 ? 1 - secondary.x : 0)
            let correctionY = secondary.y < 0 ? -secondary.y : (secondary.y > 1 ? 1 - secondary.y : 0)
            return (
                SimulatorPoint(x: point.x + correctionX, y: point.y + correctionY),
                SimulatorPoint(x: secondary.x + correctionX, y: secondary.y + correctionY)
            )
        }
        return (point, SimulatorPoint(x: 1 - point.x, y: 1 - point.y))
    }

    private func scrolledPoint(from point: SimulatorPoint, deltaX: Double, deltaY: Double) -> SimulatorPoint {
        clampedScrollPoint(unboundedScrolledPoint(
            from: point,
            deltaX: deltaX,
            deltaY: deltaY
        ))
    }

    private func unboundedScrolledPoint(
        from point: SimulatorPoint,
        deltaX: Double,
        deltaY: Double
    ) -> SimulatorInputDelta {
        let displayDelta = SimulatorInputDelta(
            x: -min(max(deltaX / 600, -0.25), 0.25),
            y: min(max(deltaY / 600, -0.25), 0.25)
        )
        return SimulatorInputDelta(x: point.x + displayDelta.x, y: point.y + displayDelta.y)
    }

    private func clampedScrollPoint(_ point: SimulatorInputDelta) -> SimulatorPoint {
        SimulatorPoint(
            x: min(max(point.x, Self.scrollEdgeMargin), 1 - Self.scrollEdgeMargin),
            y: min(max(point.y, Self.scrollEdgeMargin), 1 - Self.scrollEdgeMargin)
        )
    }

    private func clampedScrollAnchor(_ point: SimulatorPoint) -> SimulatorPoint {
        clampedScrollPoint(SimulatorInputDelta(x: point.x, y: point.y))
    }

    private func isOutsideScrollBounds(_ point: SimulatorInputDelta) -> Bool {
        point.x <= Self.scrollEdgeMargin || point.x >= 1 - Self.scrollEdgeMargin
            || point.y <= Self.scrollEdgeMargin || point.y >= 1 - Self.scrollEdgeMargin
    }

    private func scrollPointer(
        _ phase: SimulatorTouchPhase,
        at point: SimulatorPoint
    ) -> SimulatorWorkerInbound {
        let event = SimulatorPointerEvent(phase: phase, primary: point)
        return .pointer(orientationGeometry?.rawPointerEvent(event) ?? event)
    }

    private func rawScrollPoint(_ point: SimulatorPoint) -> SimulatorPoint {
        let event = SimulatorPointerEvent(phase: .moved, primary: point)
        return orientationGeometry?.rawPointerEvent(event).primary ?? point
    }

    private static let scrollEdgeMargin = 0.08
}

func simulatorEdge(at point: SimulatorPoint, threshold: Double = 0.035) -> SimulatorEdge {
    if point.x <= threshold { return .left }
    if point.x >= 1 - threshold { return .right }
    if point.y <= threshold { return .top }
    if point.y >= 1 - threshold { return .bottom }
    return .none
}
