import Testing
@testable import CmuxSimulator

@Suite("Simulator accessibility targets")
struct SimulatorAccessibilityTargetTests {
    @Test("Exact labels preserve Simulator accessibility's top-origin points")
    func labelTarget() throws {
        let snapshot = makeSnapshot(children: [
            node(
                id: "com.apple.settings.general",
                role: "Button",
                label: "General",
                frame: SimulatorRect(
                    x: 16,
                    y: 293.333_333_333_333_31,
                    width: 370,
                    height: 52
                )
            ),
        ])

        let target = try #require(snapshot.interactionTargets(
            label: "general", identifier: nil, role: "button"
        ).only)

        #expect(target.node.id == "com.apple.settings.general")
        #expect(abs(target.point.x - 0.5) < 0.000_001)
        #expect(abs(target.point.y - (319.333_333_333_333_31 / 874.0)) < 0.000_001)
    }

    @Test("Identifier and role narrow duplicate labels")
    func selectorNarrowing() throws {
        let snapshot = makeSnapshot(children: [
            node(
                id: "title", role: "StaticText", label: "General",
                frame: SimulatorRect(x: 16, y: 120, width: 100, height: 40)
            ),
            node(
                id: "0.1", identifier: "com.apple.settings.general",
                role: "Button", label: "General",
                frame: SimulatorRect(x: 16, y: 380, width: 370, height: 52)
            ),
        ])

        let target = try #require(snapshot.interactionTargets(
            label: "General",
            identifier: "com.apple.settings.general",
            role: "button"
        ).only)

        #expect(target.node.role == "Button")
        #expect(snapshot.interactionTargets(
            label: nil,
            identifier: "0.1",
            role: nil
        ).isEmpty)
    }

    @Test("Disabled and offscreen elements cannot become touch targets")
    func rejectsUnavailableTargets() {
        let snapshot = makeSnapshot(children: [
            node(
                id: "disabled", role: "Button", label: "Continue",
                frame: SimulatorRect(x: 20, y: 200, width: 100, height: 44), enabled: false
            ),
            node(
                id: "offscreen", role: "Button", label: "Continue",
                frame: SimulatorRect(x: 20, y: 1_000, width: 100, height: 44)
            ),
        ])

        #expect(snapshot.interactionTargets(
            label: "Continue", identifier: nil, role: nil
        ).isEmpty)
    }

    @Test("Duplicate visible labels remain ambiguous")
    func preservesAmbiguity() {
        let snapshot = makeSnapshot(children: [
            node(
                id: "first", role: "Button", label: "Continue",
                frame: SimulatorRect(x: 20, y: 200, width: 100, height: 44)
            ),
            node(
                id: "second", role: "Button", label: "Continue",
                frame: SimulatorRect(x: 20, y: 300, width: 100, height: 44)
            ),
        ])

        #expect(snapshot.interactionTargets(
            label: "Continue", identifier: nil, role: nil
        ).count == 2)
    }

    @Test("Role alone is insufficient to select a target")
    func rejectsRoleOnlySelector() {
        let snapshot = makeSnapshot(children: [
            node(
                id: "com.apple.settings.general",
                role: "Button",
                label: "General",
                frame: SimulatorRect(x: 16, y: 380, width: 370, height: 52)
            ),
        ])

        #expect(snapshot.interactionTargets(
            label: nil, identifier: nil, role: "Button"
        ).isEmpty)
    }

    @Test("Truncated selector fields fail closed without hiding complete fields")
    func rejectsTruncatedSelectorFields() {
        let snapshot = makeSnapshot(children: [
            node(
                id: "complete-identifier",
                identifier: "continue.button",
                role: "Button",
                label: "Continue",
                isLabelTruncated: true,
                frame: SimulatorRect(x: 20, y: 200, width: 100, height: 44)
            ),
            node(
                id: "complete-label",
                identifier: "continue.button",
                isIdentifierTruncated: true,
                role: "Button",
                label: "Continue",
                frame: SimulatorRect(x: 20, y: 300, width: 100, height: 44)
            ),
        ])

        #expect(snapshot.interactionTargets(
            label: "Continue", identifier: nil, role: nil
        ).map(\.node.id) == ["complete-label"])
        #expect(snapshot.interactionTargets(
            label: nil, identifier: "continue.button", role: nil
        ).map(\.node.id) == ["complete-identifier"])
    }

    private func makeSnapshot(
        children: [SimulatorAccessibilityNode]
    ) -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [node(
                id: "app", role: "Application", label: "Settings",
                frame: SimulatorRect(x: 0, y: 0, width: 402, height: 874),
                children: children
            )],
            display: SimulatorDisplayMetadata(
                width: 1_206,
                height: 2_622,
                orientation: .portrait,
                scale: 1
            )
        )
    }

    private func node(
        id: String,
        identifier: String? = nil,
        isIdentifierTruncated: Bool = false,
        role: String,
        label: String,
        isLabelTruncated: Bool = false,
        frame: SimulatorRect,
        enabled: Bool = true,
        children: [SimulatorAccessibilityNode] = []
    ) -> SimulatorAccessibilityNode {
        SimulatorAccessibilityNode(
            id: id,
            identifier: identifier,
            isIdentifierTruncated: isIdentifierTruncated,
            role: role,
            label: label,
            isLabelTruncated: isLabelTruncated,
            value: nil,
            frame: frame,
            isEnabled: enabled,
            children: children
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
