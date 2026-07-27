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
                id: "com.apple.settings.general", role: "Button", label: "General",
                frame: SimulatorRect(x: 16, y: 380, width: 370, height: 52)
            ),
        ])

        let target = try #require(snapshot.interactionTargets(
            label: "General",
            identifier: "com.apple.settings.general",
            role: "button"
        ).only)

        #expect(target.node.role == "Button")
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
        role: String,
        label: String,
        frame: SimulatorRect,
        enabled: Bool = true,
        children: [SimulatorAccessibilityNode] = []
    ) -> SimulatorAccessibilityNode {
        SimulatorAccessibilityNode(
            id: id,
            role: role,
            label: label,
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
