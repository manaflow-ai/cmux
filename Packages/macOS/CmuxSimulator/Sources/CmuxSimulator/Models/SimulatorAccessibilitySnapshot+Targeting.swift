import Foundation

extension SimulatorAccessibilitySnapshot {
    /// Finds visible enabled elements matching an exact accessibility selector.
    ///
    /// The returned point uses the largest root frame as the foreground app
    /// viewport. Simulator's accessibility translator reports top-origin device
    /// points, which align with normalized touch input even when framebuffer
    /// metadata is expressed in pixels.
    ///
    /// - Parameters:
    ///   - label: An exact accessibility label, compared case-insensitively.
    ///   - identifier: An exact accessibility identifier.
    ///   - role: An exact accessibility role, compared case-insensitively.
    /// - Returns: Matching elements in accessibility traversal order.
    public func interactionTargets(
        label: String?,
        identifier: String?,
        role: String?
    ) -> [SimulatorAccessibilityTarget] {
        guard label != nil || identifier != nil,
              let viewport = roots.compactMap(\.frame).filter(validFrame).max(by: {
                  $0.width * $0.height < $1.width * $1.height
              }) else {
            return []
        }

        var pending = Array(roots.reversed())
        var targets: [SimulatorAccessibilityTarget] = []
        while let node = pending.popLast() {
            pending.append(contentsOf: node.children.reversed())
            guard node.isEnabled != false,
                  matches(node.label, expected: label, caseInsensitive: true),
                  matches(node.id, expected: identifier, caseInsensitive: false),
                  matches(node.role, expected: role, caseInsensitive: true),
                  let frame = node.frame,
                  validFrame(frame) else {
                continue
            }
            let centerX = frame.x + frame.width / 2
            let centerY = frame.y + frame.height / 2
            guard centerX >= viewport.x,
                  centerX <= viewport.x + viewport.width,
                  centerY >= viewport.y,
                  centerY <= viewport.y + viewport.height else {
                continue
            }
            targets.append(SimulatorAccessibilityTarget(
                node: node,
                point: SimulatorPoint(
                    x: (centerX - viewport.x) / viewport.width,
                    y: (centerY - viewport.y) / viewport.height
                )
            ))
        }
        return targets
    }

    private func validFrame(_ frame: SimulatorRect) -> Bool {
        frame.x.isFinite && frame.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    private func matches(
        _ actual: String?,
        expected: String?,
        caseInsensitive: Bool
    ) -> Bool {
        guard let expected else { return true }
        guard let actual else { return false }
        if caseInsensitive {
            return actual.compare(
                expected,
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ) == .orderedSame
        }
        return actual == expected
    }
}
