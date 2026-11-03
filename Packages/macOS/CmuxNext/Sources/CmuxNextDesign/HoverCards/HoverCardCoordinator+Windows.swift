import AppKit

// Which window is on top under the pointer, and whether the pointer is between a source's
// targets there (`HoverCardCoordinator`'s hit tests).
extension HoverCardCoordinator {
    /// Whether `point` is between the targets of a source in the window on top there.
    func bridges(at point: CGPoint) -> Bool {
        guard appIsActive(), hoverCardsEnabled() else { return false }
        let top = topWindowNumber(at: point)
        return sources.values.contains { entry in
            guard let source = entry.source, source.hoverCardWindow?.windowNumber == top else { return false }
            return source.hoverCardBridges(at: point)
        }
    }

    /// The window on top at a screen point, never the card. Asks the window server (a round trip) once per
    /// point and display frame (``topWindowCache``): a burst of relayouts in one frame under a still pointer
    /// reuses the answer; the next frame asks again.
    func topWindowNumber(at point: CGPoint) -> Int {
        let time = now()
        if let cached = topWindowCache, cached.point == point, time - cached.at < Self.topWindowLifetime, time >= cached.at {
            return cached.number
        }
        let number = (WindowPlacement.noActivate ? ownTopWindowNumber(at: point) : nil)
            ?? windowNumberAt?(point) ?? Self.topWindowNumber(at: point, excluding: panel?.windowNumber)
        topWindowCache = (point, time, number)
        return number
    }

    /// The front one of this app's windows under a screen point. A
    /// no-activate run (a capture slot) is never frontmost and sits under
    /// other runs' windows, so the system's topmost window there is often
    /// not ours.
    private func ownTopWindowNumber(at point: CGPoint) -> Int? {
        let card = panel?.windowNumber
        return ownWindows().first { $0.number != card && $0.frame.contains(point) }?.number
    }

    private static func topWindowNumber(at point: CGPoint, excluding card: Int?) -> Int {
        let top = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard let card, top == card else { return top }
        return NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: card)
    }
}
