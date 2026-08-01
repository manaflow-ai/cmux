import CryptoKit
import Foundation

/// Builds one compact UI automation snapshot from a native accessibility tree.
struct SimulatorUIAutomationSnapshotBuilder {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    private let source: SimulatorAccessibilitySnapshot
    private let simulatorID: String
    private let sequence: UInt64
    private let capturedAtMilliseconds: Int64

    init(
        source: SimulatorAccessibilitySnapshot,
        simulatorID: String,
        sequence: UInt64,
        capturedAtMilliseconds: Int64
    ) {
        self.source = source
        self.simulatorID = simulatorID
        self.sequence = sequence
        self.capturedAtMilliseconds = capturedAtMilliseconds
    }

    func build() throws -> SimulatorUIAutomationSnapshotRecord {
        guard let viewport = source.roots
            .compactMap(\.frame)
            .filter(\.isValidUIAutomationFrame)
            .max(by: {
                $0.width * $0.height < $1.width * $1.height
            }) else {
            throw SimulatorUIAutomationSnapshotError.viewportUnavailable
        }

        let preliminaryRecords = flattenedNodes(source.roots).enumerated().map { index, input in
            elementRecord(
                node: input.node,
                path: input.path,
                index: index,
                viewport: viewport,
                descendantFrameBounds: input.descendantFrameBounds
            )
        }
        let records = removingAmbiguousTypeTextActions(from: preliminaryRecords)
        let elements = records.map(\.element)
        let actions = elements.flatMap { element in
            element.actions.map {
                SimulatorUIAutomationActionHint(
                    action: $0,
                    elementRef: element.ref,
                    label: element.label
                )
            }
        }
        let snapshot = SimulatorUIAutomationSnapshot(
            simulatorID: simulatorID,
            screenHash: screenHash(
                elements: elements,
                isTruncated: source.isTruncated
            ),
            sequence: sequence,
            capturedAtMilliseconds: capturedAtMilliseconds,
            expiresAtMilliseconds:
                capturedAtMilliseconds + simulatorUIAutomationSnapshotLifetimeMilliseconds,
            elements: elements,
            actions: actions,
            isTruncated: source.isTruncated
        )
        return SimulatorUIAutomationSnapshotRecord(
            snapshot: snapshot,
            elementRecords: records,
            display: source.display
        )
    }

    private func flattenedNodes(
        _ roots: [SimulatorAccessibilityNode]
    ) -> [SimulatorUIAutomationFlattenedNode] {
        var pending = roots.enumerated().reversed().map {
            SimulatorUIAutomationPendingNode(
                node: $0.element,
                path: String($0.offset),
                parentIndex: nil
            )
        }
        var result: [SimulatorUIAutomationFlattenedNode] = []
        var parentIndices: [Int?] = []
        result.reserveCapacity(roots.reduce(0) { $0 + $1.subtreeNodeCount })
        parentIndices.reserveCapacity(result.capacity)
        while let current = pending.popLast() {
            let currentIndex = result.count
            result.append(SimulatorUIAutomationFlattenedNode(
                node: current.node,
                path: current.path,
                descendantFrameBounds: nil
            ))
            parentIndices.append(current.parentIndex)
            for (index, child) in current.node.children.enumerated().reversed() {
                pending.append(SimulatorUIAutomationPendingNode(
                    node: child,
                    path: "\(current.path).\(index)",
                    parentIndex: currentIndex
                ))
            }
        }
        for index in result.indices.reversed() {
            let nodeFrame = result[index].node.frame.flatMap {
                $0.isValidUIAutomationFrame ? $0 : nil
            }
            let subtreeBounds = mergedFrame(
                nodeFrame,
                result[index].descendantFrameBounds
            )
            guard let parentIndex = parentIndices[index] else { continue }
            result[parentIndex].descendantFrameBounds = mergedFrame(
                result[parentIndex].descendantFrameBounds,
                subtreeBounds
            )
        }
        return result
    }

    private func elementRecord(
        node: SimulatorAccessibilityNode,
        path: String,
        index: Int,
        viewport: SimulatorRect,
        descendantFrameBounds: SimulatorRect?
    ) -> SimulatorUIAutomationElementRecord {
        let frame = node.frame.flatMap {
            $0.isValidUIAutomationFrame ? $0 : nil
        } ?? SimulatorRect(x: 0, y: 0, width: 0, height: 0)
        let normalizedLabel = node.label?.normalizedUIAutomationText
        let normalizedValue = node.value?.normalizedUIAutomationText
        let normalizedIdentifier = node.identifier?.normalizedUIAutomationText
        let normalizedRawRole = node.role?.normalizedUIAutomationText
        let normalizedRoleDescription = node.roleDescription?.normalizedUIAutomationText
        let role = normalizedRole(
            normalizedRawRole,
            description: normalizedRoleDescription,
            identifier: normalizedIdentifier
        )
        let visibleFrame = frameIntersection(frame, viewport)
        let visible = visibleFrame != nil
        let enabled = node.isEnabled != false
        let hasStableInputSelector = normalizedIdentifier != nil
        let actions = supportedActions(
            node: node,
            role: role,
            hasSemanticIdentity: normalizedLabel != nil || normalizedIdentifier != nil,
            hasStableInputSelector: hasStableInputSelector,
            enabled: enabled,
            visible: visible,
            frame: frame,
            descendantFrameBounds: descendantFrameBounds
        )
        let element = SimulatorUIAutomationElement(
            ref: "e\(sequence)_\(index + 1)",
            role: role,
            label: normalizedLabel,
            value: normalizedValue,
            identifier: normalizedIdentifier,
            frame: frame,
            state: SimulatorUIAutomationElementState(
                isEnabled: enabled,
                isFocused: node.isFocused,
                isSelected: node.isSelected,
                isVisible: visible
            ),
            actions: actions
        )
        return SimulatorUIAutomationElementRecord(
            element: element,
            node: node,
            path: path,
            activationPoint: activationPoint(
                role: role,
                frame: visibleFrame ?? frame,
                viewport: viewport
            ),
            viewport: viewport,
            swipeFrame: visibleFrame
        )
    }

    private func normalizedRole(
        _ rawRole: String?,
        description: String?,
        identifier: String?
    ) -> SimulatorUIAutomationRole? {
        if description?.lowercased() == "tab" {
            return .tab
        }
        let text = [rawRole, description]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("application") { return .application }
        if text.contains("window") { return .window }
        if text.contains("keyboard") || text.contains("key") { return .keyboardKey }
        if text.contains("button") { return .button }
        if text.contains("textfield") || text.contains("text field")
            || text.contains("searchfield") || text.contains("search field")
            || text.contains("securetext") || text.contains("textarea")
            || text.contains("textview") || text.contains("text view") {
            return .textField
        }
        if text.contains("menu") { return .menu }
        if text.contains("statictext") || text.contains("text") { return .text }
        if text.contains("image") { return .image }
        if text.contains("switch") || text.contains("checkbox")
            || text.contains("check box") {
            return .switch
        }
        if text.contains("slider") { return .slider }
        if text.contains("cell") || text.contains("row") { return .cell }
        if text.contains("scroll") { return .scrollView }
        if text.contains("table") || text.contains("list")
            || text.contains("outline") || text.contains("collection") {
            return .list
        }
        if isScrollSemanticIdentifier(identifier),
           text.contains("group") || text.contains("view")
            || text.contains("container") || text.contains("other") {
            return .scrollView
        }
        if text == "tab" || text.contains("tab group") || text.contains("axtab") {
            return .tab
        }
        return .other
    }

    private func supportedActions(
        node: SimulatorAccessibilityNode,
        role: SimulatorUIAutomationRole?,
        hasSemanticIdentity: Bool,
        hasStableInputSelector: Bool,
        enabled: Bool,
        visible: Bool,
        frame: SimulatorRect,
        descendantFrameBounds: SimulatorRect?
    ) -> [SimulatorUIAutomationActionName] {
        guard enabled, visible else { return [] }
        var actions: [SimulatorUIAutomationActionName] = []
        let tapRoles: Set<SimulatorUIAutomationRole> = [
            .button, .cell, .keyboardKey, .switch, .tab, .textField,
        ]
        if role.map(tapRoles.contains) == true
            || (hasSemanticIdentity && node.children.isEmpty && role != .text) {
            actions.append(.tap)
        }
        if role == .textField, hasStableInputSelector {
            actions.append(.typeText)
        }
        if role != .application, role != .window {
            actions.append(.longPress)
            actions.append(.touch)
        }
        if role == .scrollView || role == .list || role == .cell
            || inferredScrollableContainer(
                node: node,
                frame: frame,
                role: role,
                descendantFrameBounds: descendantFrameBounds
            ) {
            actions.append(.swipeWithin)
        }
        return actions
    }

    private func inferredScrollableContainer(
        node: SimulatorAccessibilityNode,
        frame: SimulatorRect,
        role: SimulatorUIAutomationRole?,
        descendantFrameBounds: SimulatorRect?
    ) -> Bool {
        guard role == .application || role == .window || role == .other,
              frame.width >= 100, frame.height >= 100,
              !node.children.isEmpty,
              let descendantFrameBounds else {
            return false
        }
        let tolerance = 8.0
        return descendantFrameBounds.x < frame.x - tolerance
            || descendantFrameBounds.y < frame.y - tolerance
            || descendantFrameBounds.x + descendantFrameBounds.width
                > frame.x + frame.width + tolerance
            || descendantFrameBounds.y + descendantFrameBounds.height
                > frame.y + frame.height + tolerance
    }

    private func mergedFrame(
        _ first: SimulatorRect?,
        _ second: SimulatorRect?
    ) -> SimulatorRect? {
        guard let first else { return second }
        guard let second else { return first }
        let minimumX = min(first.x, second.x)
        let minimumY = min(first.y, second.y)
        let maximumX = max(first.x + first.width, second.x + second.width)
        let maximumY = max(first.y + first.height, second.y + second.height)
        return SimulatorRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private func isScrollSemanticIdentifier(_ identifier: String?) -> Bool {
        guard let identifier = identifier?.lowercased() else {
            return false
        }
        return identifier.contains("scrollview")
            || identifier.contains("scroll-view")
            || identifier.contains("scroll_view")
            || identifier == "scroll"
            || identifier.hasSuffix(".scroll")
            || identifier.hasSuffix("-scroll")
            || identifier.hasSuffix("_scroll")
    }

    private func activationPoint(
        role: SimulatorUIAutomationRole?,
        frame: SimulatorRect,
        viewport: SimulatorRect
    ) -> SimulatorPoint {
        var x = frame.x + frame.width / 2
        var y = frame.y + frame.height / 2
        if role == .switch, frame.width > 120 {
            x = frame.x + frame.width - min(52, frame.width / 4)
        }
        let bottomThreshold = viewport.y + viewport.height * 0.93
        if y >= bottomThreshold, frame.height > 0 {
            y = frame.y + min(max(frame.height * 0.1, 8), frame.height / 2)
        }
        return SimulatorPoint(
            x: (x - viewport.x) / viewport.width,
            y: (y - viewport.y) / viewport.height
        )
    }

    private func screenHash(
        elements: [SimulatorUIAutomationElement],
        isTruncated: Bool
    ) -> String {
        let stableElements = elements.filter(\.state.isVisible).enumerated().map { index, element in
            SimulatorUIAutomationElement(
                ref: "e\(index + 1)",
                role: element.role,
                label: element.label,
                value: element.value,
                identifier: element.identifier,
                frame: element.frame,
                state: element.state,
                actions: element.actions
            )
        }
        let stableActions = stableElements.flatMap { element in
            element.actions.map {
                SimulatorUIAutomationActionHint(
                    action: $0,
                    elementRef: element.ref,
                    label: element.label
                )
            }
        }
        let payload = SimulatorUIAutomationScreenHashPayload(
            protocol: simulatorUIAutomationProtocol,
            elements: stableElements,
            actions: stableActions,
            isTruncated: isTruncated
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(24)
        for byte in SHA256.hash(data: data).prefix(12) {
            bytes.append(Self.hexDigits[Int(byte >> 4)])
            bytes.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func removingAmbiguousTypeTextActions(
        from records: [SimulatorUIAutomationElementRecord]
    ) -> [SimulatorUIAutomationElementRecord] {
        let elements = records.map(\.element)
        return records.map { record in
            let element = record.element
            guard element.actions.contains(.typeText) else { return record }
            let hasUniqueSelector = !source.isTruncated && (
                element.stableInputSelector.map { selector in
                    elements.lazy.filter {
                        $0.state.isVisible && selector.matches($0)
                    }.prefix(2).count == 1
                } ?? false
            )
            guard !hasUniqueSelector else {
                return record
            }
            let filteredElement = SimulatorUIAutomationElement(
                ref: element.ref,
                role: element.role,
                label: element.label,
                value: element.value,
                identifier: element.identifier,
                frame: element.frame,
                state: element.state,
                actions: element.actions.filter { $0 != .typeText }
            )
            return SimulatorUIAutomationElementRecord(
                element: filteredElement,
                node: record.node,
                path: record.path,
                activationPoint: record.activationPoint,
                viewport: record.viewport,
                swipeFrame: record.swipeFrame
            )
        }
    }

    private func framesIntersect(
        _ first: SimulatorRect,
        _ second: SimulatorRect
    ) -> Bool {
        first.x < second.x + second.width
            && first.x + first.width > second.x
            && first.y < second.y + second.height
            && first.y + first.height > second.y
    }

    private func frameIntersection(
        _ first: SimulatorRect,
        _ second: SimulatorRect
    ) -> SimulatorRect? {
        guard first.isValidUIAutomationFrame,
              second.isValidUIAutomationFrame,
              framesIntersect(first, second) else {
            return nil
        }
        let x = max(first.x, second.x)
        let y = max(first.y, second.y)
        return SimulatorRect(
            x: x,
            y: y,
            width: min(first.x + first.width, second.x + second.width) - x,
            height: min(first.y + first.height, second.y + second.height) - y
        )
    }
}
