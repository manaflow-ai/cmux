import Foundation

extension SimulatorUIAutomationSnapshotRecord {
    /// Returns candidates whose populated selector fields all match exactly.
    ///
    /// - Parameter selector: The exact semantic selector.
    /// - Returns: Matching public elements in snapshot order.
    public func matching(
        _ selector: SimulatorUIAutomationSelector
    ) -> [SimulatorUIAutomationElement] {
        snapshot.elements.filter { element in
            if let identifier = selector.identifier, element.identifier != identifier {
                return false
            }
            if let label = selector.label, element.label != label {
                return false
            }
            if let role = selector.role, element.role != role {
                return false
            }
            if let value = selector.value, element.value != value {
                return false
            }
            return true
        }
    }

    /// Returns elements whose visible label or value contains text case-insensitively.
    ///
    /// - Parameter text: The nonempty text fragment.
    /// - Returns: Matching public elements in snapshot order.
    public func containingText(_ text: String) -> [SimulatorUIAutomationElement] {
        let needle = normalizedText(text).lowercased()
        guard !needle.isEmpty else { return [] }
        return snapshot.elements.filter {
            normalizedText($0.label).lowercased().contains(needle)
                || normalizedText($0.value).lowercased().contains(needle)
        }
    }

    /// Reports whether every candidate matched the same normalized visible text.
    ///
    /// This lets partial-text waits accept repeated copies of one visible string
    /// while rejecting selectors that match different strings.
    ///
    /// - Parameters:
    ///   - candidates: Elements already known to contain the requested text.
    ///   - text: The nonempty text fragment.
    /// - Returns: `true` when every candidate matched the same label or value.
    public func candidatesShareMatchingText(
        _ candidates: [SimulatorUIAutomationElement],
        containing text: String
    ) -> Bool {
        let matches = candidates.compactMap {
            matchingText(in: $0, containing: text)
        }
        guard let first = matches.first, matches.count == candidates.count else {
            return false
        }
        return matches.dropFirst().allSatisfy { $0 == first }
    }

    /// Converts one current ref into selector fields that survive a refreshed snapshot.
    ///
    /// - Parameter elementRef: The current process-scoped reference.
    /// - Returns: The strongest stable selector available, or `nil` when none exists.
    public func stableSelector(
        for elementRef: String
    ) -> SimulatorUIAutomationSelector? {
        guard let element = elementsByRef[elementRef]?.element else { return nil }
        if let identifier = element.identifier {
            return SimulatorUIAutomationSelector(
                sourceElementRef: elementRef,
                identifier: identifier
            )
        }
        if let label = element.label, let role = element.role {
            return SimulatorUIAutomationSelector(
                sourceElementRef: elementRef,
                label: label,
                role: role
            )
        }
        if let value = element.value, let role = element.role {
            return SimulatorUIAutomationSelector(
                sourceElementRef: elementRef,
                role: role,
                value: value
            )
        }
        return nil
    }

    /// Resolves a swipe wholly inside the target's visible frame.
    ///
    /// - Parameters:
    ///   - elementRef: The current target reference.
    ///   - direction: The semantic movement direction.
    ///   - distance: The fraction of the available target span to traverse.
    /// - Returns: Normalized gesture endpoints, or `nil` for an unusable target.
    public func swipePoints(
        elementRef: String,
        direction: SimulatorUIAutomationDirection,
        distance: Double
    ) -> SimulatorUIAutomationGesturePoints? {
        guard let record = elementsByRef[elementRef] else { return nil }
        return directionalPoints(
            frame: record.swipeFrame ?? record.element.frame,
            viewport: record.viewport,
            direction: direction,
            distance: distance,
            centeredOnActivationPoint: false,
            activationPoint: record.activationPoint
        )
    }

    /// Resolves a directional drag starting from the target activation point.
    ///
    /// - Parameters:
    ///   - elementRef: The current target reference.
    ///   - direction: The semantic movement direction.
    ///   - distance: The fraction of the available span to traverse.
    /// - Returns: Normalized gesture endpoints, or `nil` for an unusable target.
    public func dragPoints(
        elementRef: String,
        direction: SimulatorUIAutomationDirection,
        distance: Double
    ) -> SimulatorUIAutomationGesturePoints? {
        guard let record = elementsByRef[elementRef] else { return nil }
        let usesContainerFrame = record.element.actions.contains(.swipeWithin)
            && [.application, .window, .scrollView, .list].contains(record.element.role)
        if usesContainerFrame {
            return swipePoints(
                elementRef: elementRef,
                direction: direction,
                distance: distance
            )
        }
        return directionalPoints(
            frame: record.viewport,
            viewport: record.viewport,
            direction: direction,
            distance: distance,
            centeredOnActivationPoint: true,
            activationPoint: record.activationPoint
        )
    }

    private func directionalPoints(
        frame: SimulatorRect,
        viewport: SimulatorRect,
        direction: SimulatorUIAutomationDirection,
        distance: Double,
        centeredOnActivationPoint: Bool,
        activationPoint: SimulatorPoint
    ) -> SimulatorUIAutomationGesturePoints? {
        guard isValidFrame(frame), isValidFrame(viewport),
              distance.isFinite, distance > 0, distance <= 1 else {
            return nil
        }
        let normalizedFrame = SimulatorRect(
            x: (frame.x - viewport.x) / viewport.width,
            y: (frame.y - viewport.y) / viewport.height,
            width: frame.width / viewport.width,
            height: frame.height / viewport.height
        )
        let horizontalInset = min(
            max(24 / viewport.width, normalizedFrame.width * 0.15),
            normalizedFrame.width / 3
        )
        let verticalInset = min(
            max(24 / viewport.height, normalizedFrame.height * 0.15),
            normalizedFrame.height / 3
        )
        let left = normalizedFrame.x + horizontalInset
        let right = normalizedFrame.x + normalizedFrame.width - horizontalInset
        let top = normalizedFrame.y + verticalInset
        let bottom = normalizedFrame.y + normalizedFrame.height - verticalInset
        guard right > left, bottom > top else { return nil }

        let centerX = centeredOnActivationPoint ? activationPoint.x : (left + right) / 2
        let centerY = centeredOnActivationPoint ? activationPoint.y : (top + bottom) / 2
        let horizontalStroke = (right - left) * distance
        let verticalStroke = (bottom - top) * distance
        let rawFrom: SimulatorPoint
        let rawTo: SimulatorPoint
        switch direction {
        case .up:
            rawFrom = SimulatorPoint(
                x: centerX,
                y: min(bottom, centerY + verticalStroke / 2)
            )
            rawTo = SimulatorPoint(
                x: centerX,
                y: max(top, rawFrom.y - verticalStroke)
            )
        case .down:
            rawFrom = SimulatorPoint(
                x: centerX,
                y: max(top, centerY - verticalStroke / 2)
            )
            rawTo = SimulatorPoint(
                x: centerX,
                y: min(bottom, rawFrom.y + verticalStroke)
            )
        case .left:
            rawFrom = SimulatorPoint(
                x: min(right, centerX + horizontalStroke / 2),
                y: centerY
            )
            rawTo = SimulatorPoint(
                x: max(left, rawFrom.x - horizontalStroke),
                y: centerY
            )
        case .right:
            rawFrom = SimulatorPoint(
                x: max(left, centerX - horizontalStroke / 2),
                y: centerY
            )
            rawTo = SimulatorPoint(
                x: min(right, rawFrom.x + horizontalStroke),
                y: centerY
            )
        }
        guard rawFrom != rawTo else { return nil }
        return SimulatorUIAutomationGesturePoints(from: rawFrom, to: rawTo)
    }

    private func isValidFrame(_ frame: SimulatorRect) -> Bool {
        frame.x.isFinite && frame.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    private func normalizedText(_ value: String?) -> String {
        guard let normalized = value?.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return ""
        }
        return normalized
    }

    private func matchingText(
        in element: SimulatorUIAutomationElement,
        containing text: String
    ) -> String? {
        let needle = normalizedText(text).lowercased()
        guard !needle.isEmpty else { return nil }
        let value = normalizedText(element.value).lowercased()
        if value.contains(needle) {
            return value
        }
        let label = normalizedText(element.label).lowercased()
        return label.contains(needle) ? label : nil
    }
}
