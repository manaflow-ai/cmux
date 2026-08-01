import Foundation

extension SimulatorUIAutomationSnapshotRecord {
    /// Returns visible enabled records matching an exact accessibility selector.
    ///
    /// Labels and roles use case-insensitive comparison. Identifiers retain
    /// the native bridge's exact-match contract.
    public func accessibilityInteractionTargets(
        label: String?,
        identifier: String?,
        role: String?
    ) -> [SimulatorUIAutomationElementRecord] {
        guard label != nil || identifier != nil else { return [] }
        return elementRecords.filter { record in
            let node = record.node
            return node.isEnabled != false
                && record.element.state.isVisible
                && accessibilityValue(
                    node.label,
                    matches: label,
                    caseInsensitive: true
                )
                && accessibilityValue(
                    node.identifier,
                    matches: identifier,
                    caseInsensitive: false
                )
                && (
                    role == nil
                        || accessibilityValue(
                            record.element.role?.rawValue,
                            matches: role,
                            caseInsensitive: true
                        )
                        || accessibilityValue(
                            node.role,
                            matches: role,
                            caseInsensitive: true
                        )
                )
        }
    }

    /// Returns candidates whose populated selector fields all match exactly.
    ///
    /// - Parameter selector: The exact semantic selector.
    /// - Returns: Matching public elements in snapshot order.
    public func matching(
        _ selector: SimulatorUIAutomationSelector
    ) -> [SimulatorUIAutomationElement] {
        snapshot.elements.filter {
            $0.state.isVisible && selector.matches($0)
        }
    }

    /// Returns elements whose visible label or value contains text case-insensitively.
    ///
    /// - Parameter text: The nonempty text fragment.
    /// - Returns: Matching public elements in snapshot order.
    public func containingText(_ text: String) -> [SimulatorUIAutomationElement] {
        let needle = (text.normalizedUIAutomationText ?? "").lowercased()
        guard !needle.isEmpty else { return [] }
        return snapshot.elements.filter {
            $0.state.isVisible
                && (
                    ($0.label ?? "").lowercased().contains(needle)
                        || ($0.value ?? "").lowercased().contains(needle)
                )
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
        let needle = (text.normalizedUIAutomationText ?? "").lowercased()
        guard !needle.isEmpty else { return false }
        let matches = candidates.compactMap {
            matchingText(in: $0, containingNormalized: needle)
        }
        guard let first = matches.first, matches.count == candidates.count else {
            return false
        }
        return matches.dropFirst().allSatisfy { $0 == first }
    }

    /// Converts one current ref into selector fields that survive a refreshed snapshot.
    ///
    /// - Parameter elementRef: The current snapshot-scoped reference.
    /// - Returns: The strongest stable selector available, or `nil` when none exists.
    public func stableSelector(
        for elementRef: String
    ) -> SimulatorUIAutomationSelector? {
        guard !snapshot.isTruncated else { return nil }
        return elementsByRef[elementRef]?.element.stableSelector
    }

    /// Returns an identifier-only selector that can safely route un-targeted input.
    ///
    /// Labels and values may identify replacement elements after a UI mutation,
    /// so they remain suitable for observation waits but never for typing.
    public func stableInputSelector(
        for elementRef: String
    ) -> SimulatorUIAutomationSelector? {
        guard !snapshot.isTruncated else { return nil }
        return elementsByRef[elementRef]?.element.stableInputSelector
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
            startsAtActivationPoint: false,
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
            startsAtActivationPoint: true,
            activationPoint: record.activationPoint
        )
    }

    private func directionalPoints(
        frame: SimulatorRect,
        viewport: SimulatorRect,
        direction: SimulatorUIAutomationDirection,
        distance: Double,
        startsAtActivationPoint: Bool,
        activationPoint: SimulatorPoint
    ) -> SimulatorUIAutomationGesturePoints? {
        guard frame.isValidUIAutomationFrame,
              viewport.isValidUIAutomationFrame,
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

        let horizontalStroke = (right - left) * distance
        let verticalStroke = (bottom - top) * distance
        let rawFrom: SimulatorPoint
        let rawTo: SimulatorPoint
        if startsAtActivationPoint {
            rawFrom = activationPoint
            switch direction {
            case .up:
                rawTo = SimulatorPoint(
                    x: rawFrom.x,
                    y: max(0, rawFrom.y - verticalStroke)
                )
            case .down:
                rawTo = SimulatorPoint(
                    x: rawFrom.x,
                    y: min(1, rawFrom.y + verticalStroke)
                )
            case .left:
                rawTo = SimulatorPoint(
                    x: max(0, rawFrom.x - horizontalStroke),
                    y: rawFrom.y
                )
            case .right:
                rawTo = SimulatorPoint(
                    x: min(1, rawFrom.x + horizontalStroke),
                    y: rawFrom.y
                )
            }
            guard rawFrom != rawTo else { return nil }
            return SimulatorUIAutomationGesturePoints(from: rawFrom, to: rawTo)
        }
        let centerX = (left + right) / 2
        let centerY = (top + bottom) / 2
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

    private func matchingText(
        in element: SimulatorUIAutomationElement,
        containingNormalized needle: String
    ) -> String? {
        let value = (element.value ?? "").lowercased()
        if value.contains(needle) {
            return value
        }
        let label = (element.label ?? "").lowercased()
        return label.contains(needle) ? label : nil
    }

    private func accessibilityValue(
        _ actual: String?,
        matches expected: String?,
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

extension SimulatorUIAutomationElement {
    var stableInputSelector: SimulatorUIAutomationSelector? {
        guard let identifier else { return nil }
        return SimulatorUIAutomationSelector(
            sourceElementRef: ref,
            identifier: identifier
        )
    }

    var stableSelector: SimulatorUIAutomationSelector? {
        if let stableInputSelector {
            return stableInputSelector
        }
        if let label, let role {
            return SimulatorUIAutomationSelector(
                sourceElementRef: ref,
                label: label,
                role: role
            )
        }
        if let value, let role {
            return SimulatorUIAutomationSelector(
                sourceElementRef: ref,
                role: role,
                value: value
            )
        }
        return nil
    }
}

extension SimulatorUIAutomationSelector {
    func matches(_ element: SimulatorUIAutomationElement) -> Bool {
        if let identifier, element.identifier != identifier { return false }
        if let label, element.label != label { return false }
        if let role, element.role != role { return false }
        if let value, element.value != value { return false }
        return true
    }
}
