import CryptoKit
import Foundation

/// Builds one compact UI automation snapshot from a native accessibility tree.
struct SimulatorUIAutomationSnapshotBuilder {
    private struct FlattenedNode {
        let node: SimulatorAccessibilityNode
        let path: String
    }

    private struct ScreenHashPayload: Encodable {
        let `protocol`: String
        let elements: [SimulatorUIAutomationElement]
        let actions: [SimulatorUIAutomationActionHint]
        let isTruncated: Bool
    }

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
            .filter(isValidFrame)
            .max(by: {
                $0.width * $0.height < $1.width * $1.height
            }) else {
            throw SimulatorUIAutomationSnapshotError.viewportUnavailable
        }

        let records = flattenedNodes(source.roots).enumerated().map { index, input in
            elementRecord(
                node: input.node,
                path: input.path,
                index: index,
                viewport: viewport
            )
        }
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
                actions: actions,
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
            elementRecords: records
        )
    }

    private func flattenedNodes(
        _ roots: [SimulatorAccessibilityNode]
    ) -> [FlattenedNode] {
        var pending = roots.enumerated().reversed().map {
            FlattenedNode(node: $0.element, path: String($0.offset))
        }
        var result: [FlattenedNode] = []
        result.reserveCapacity(roots.reduce(0) { $0 + $1.subtreeNodeCount })
        while let current = pending.popLast() {
            result.append(current)
            for (index, child) in current.node.children.enumerated().reversed() {
                pending.append(FlattenedNode(
                    node: child,
                    path: "\(current.path).\(index)"
                ))
            }
        }
        return result
    }

    private func elementRecord(
        node: SimulatorAccessibilityNode,
        path: String,
        index: Int,
        viewport: SimulatorRect
    ) -> SimulatorUIAutomationElementRecord {
        let frame = node.frame ?? SimulatorRect(x: 0, y: 0, width: 0, height: 0)
        let role = normalizedRole(
            node.role,
            description: node.roleDescription,
            identifier: node.identifier
        )
        let visibleFrame = frameIntersection(frame, viewport)
        let visible = visibleFrame != nil
        let enabled = node.isEnabled != false
        let actions = supportedActions(
            node: node,
            role: role,
            enabled: enabled,
            visible: visible,
            frame: frame
        )
        let element = SimulatorUIAutomationElement(
            ref: "e\(index + 1)",
            role: role,
            label: nonempty(node.label),
            value: nonempty(node.value),
            identifier: nonempty(node.identifier),
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
        let normalizedDescription = nonempty(description)?.lowercased()
        if normalizedDescription == "tab" {
            return .tab
        }
        let text = [rawRole, description]
            .compactMap(nonempty)
            .joined(separator: " ")
            .lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("application") { return .application }
        if text.contains("window") { return .window }
        if text.contains("button") { return .button }
        if text.contains("keyboard") || text.contains("key") { return .keyboardKey }
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
        enabled: Bool,
        visible: Bool,
        frame: SimulatorRect
    ) -> [SimulatorUIAutomationActionName] {
        guard enabled, visible else { return [] }
        var actions: [SimulatorUIAutomationActionName] = []
        let tapRoles: Set<SimulatorUIAutomationRole> = [
            .button, .cell, .keyboardKey, .switch, .tab, .textField,
        ]
        let hasSemanticIdentity = nonempty(node.label) != nil
            || nonempty(node.identifier) != nil
        if role.map(tapRoles.contains) == true
            || (hasSemanticIdentity && node.children.isEmpty && role != .text) {
            actions.append(.tap)
        }
        if role == .textField {
            actions.append(.typeText)
        }
        if role != .application, role != .window {
            actions.append(.longPress)
            actions.append(.touch)
        }
        if role == .scrollView || role == .list || role == .cell
            || inferredScrollableContainer(node: node, frame: frame, role: role) {
            actions.append(.swipeWithin)
        }
        return actions
    }

    private func inferredScrollableContainer(
        node: SimulatorAccessibilityNode,
        frame: SimulatorRect,
        role: SimulatorUIAutomationRole?
    ) -> Bool {
        guard role == .application || role == .window || role == .other,
              frame.width >= 100, frame.height >= 100,
              !node.children.isEmpty else {
            return false
        }
        let tolerance = 8.0
        var pending = node.children
        while let descendant = pending.popLast() {
            if let childFrame = descendant.frame, isValidFrame(childFrame),
               childFrame.x < frame.x - tolerance
                || childFrame.y < frame.y - tolerance
                || childFrame.x + childFrame.width > frame.x + frame.width + tolerance
                || childFrame.y + childFrame.height > frame.y + frame.height + tolerance {
                return true
            }
            pending.append(contentsOf: descendant.children)
        }
        return false
    }

    private func isScrollSemanticIdentifier(_ identifier: String?) -> Bool {
        guard let identifier = nonempty(identifier)?.lowercased() else {
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
        actions: [SimulatorUIAutomationActionHint],
        isTruncated: Bool
    ) -> String {
        let payload = ScreenHashPayload(
            protocol: simulatorUIAutomationProtocol,
            elements: elements,
            actions: actions,
            isTruncated: isTruncated
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func isValidFrame(_ frame: SimulatorRect) -> Bool {
        frame.x.isFinite && frame.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
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
        guard framesIntersect(first, second) else { return nil }
        let x = max(first.x, second.x)
        let y = max(first.y, second.y)
        return SimulatorRect(
            x: x,
            y: y,
            width: min(first.x + first.width, second.x + second.width) - x,
            height: min(first.y + first.height, second.y + second.height) - y
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let normalized = value?.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}
