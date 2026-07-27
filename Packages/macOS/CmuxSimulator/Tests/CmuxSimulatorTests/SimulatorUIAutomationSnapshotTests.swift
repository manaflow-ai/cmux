import Testing
@testable import CmuxSimulator

@Suite("Simulator UI automation snapshots")
struct SimulatorUIAutomationSnapshotTests {
    @Test("Snapshots expose deterministic refs, normalized roles, state, and actions")
    func compactSnapshotContract() throws {
        let record = try snapshot().uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 7,
            capturedAtMilliseconds: 1_000
        )

        #expect(record.snapshot.protocol == "rs/1")
        #expect(record.snapshot.sequence == 7)
        #expect(record.snapshot.expiresAtMilliseconds == 61_000)
        #expect(record.snapshot.elements.map(\.ref) == ["e1", "e2", "e3", "e4"])

        let button = try #require(record.element(ref: "e2")?.element)
        #expect(button.identifier == "settings.general")
        #expect(button.role == .button)
        #expect(button.state.isEnabled)
        #expect(button.state.isFocused == false)
        #expect(button.actions == [.tap, .longPress, .touch])

        let textField = try #require(record.element(ref: "e3")?.element)
        #expect(textField.role == .textField)
        #expect(textField.state.isFocused == true)
        #expect(textField.actions.contains(.typeText))

        let list = try #require(record.element(ref: "e4")?.element)
        #expect(list.role == .scrollView)
        #expect(list.actions.contains(.swipeWithin))
        #expect(record.snapshot.actions.contains {
            $0.elementRef == "e3" && $0.action == .typeText
        })
    }

    @Test("Screen hashes ignore capture sequence but include visible state")
    func screenHashTracksUIState() throws {
        let first = try snapshot().uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 1,
            capturedAtMilliseconds: 1_000
        )
        let second = try snapshot().uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 2,
            capturedAtMilliseconds: 5_000
        )
        let changed = try snapshot(searchFocused: false).uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 3,
            capturedAtMilliseconds: 5_000
        )

        #expect(first.snapshot.screenHash == second.snapshot.screenHash)
        #expect(first.snapshot.screenHash != changed.snapshot.screenHash)
    }

    @Test("Stable selectors prefer runtime identifiers and directional points stay bounded")
    func selectorsAndGesturePoints() throws {
        let record = try snapshot().uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 1,
            capturedAtMilliseconds: 1_000
        )

        let selector = try #require(record.stableSelector(for: "e2"))
        #expect(selector.identifier == "settings.general")
        #expect(selector.label == nil)

        let swipe = try #require(record.swipePoints(
            elementRef: "e4",
            direction: .up,
            distance: 1
        ))
        #expect(swipe.from.y > swipe.to.y)
        #expect((0...1).contains(swipe.from.x))
        #expect((0...1).contains(swipe.from.y))
        #expect((0...1).contains(swipe.to.x))
        #expect((0...1).contains(swipe.to.y))

        let drag = try #require(record.dragPoints(
            elementRef: "e2",
            direction: .right,
            distance: 0.5
        ))
        #expect(drag.from.x < drag.to.x)
        #expect((0...1).contains(drag.from.x))
        #expect((0...1).contains(drag.to.x))
    }

    @Test("Exact waits match public fields and normalized visible text")
    func matchingSelectorsAndText() throws {
        let record = try snapshot().uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 1,
            capturedAtMilliseconds: 1_000
        )

        #expect(record.matching(SimulatorUIAutomationSelector(
            label: "General",
            role: .button
        )).map(\.ref) == ["e2"])
        #expect(record.containingText("search").map(\.ref) == ["e3"])
        #expect(record.containingText("GENERAL").map(\.ref) == ["e2"])

        let repeated = [
            try #require(record.element(ref: "e2")?.element),
            try #require(record.element(ref: "e2")?.element),
        ]
        let distinct = repeated + [try #require(record.element(ref: "e3")?.element)]
        #expect(record.candidatesShareMatchingText(repeated, containing: "general"))
        #expect(!record.candidatesShareMatchingText(distinct, containing: "e"))
    }

    @Test("Role descriptions and clipped targets remain semantic and actionable")
    func roleDescriptionsAndClippedTargets() throws {
        let source = SimulatorAccessibilitySnapshot(
            roots: [
                node(
                    id: "0",
                    role: "Application",
                    label: "Example",
                    frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                    children: [
                        SimulatorAccessibilityNode(
                            id: "0.0",
                            identifier: "example.tab",
                            role: "Group",
                            label: "Library",
                            value: nil,
                            roleDescription: "Tab",
                            frame: SimulatorRect(x: 20, y: 800, width: 120, height: 80),
                            isEnabled: true,
                            children: []
                        ),
                        SimulatorAccessibilityNode(
                            id: "0.1",
                            identifier: "content.scrollView",
                            role: "Group",
                            label: "Content",
                            value: nil,
                            frame: SimulatorRect(x: 0, y: 100, width: 390, height: 650),
                            isEnabled: true,
                            children: []
                        ),
                    ]
                ),
            ],
            display: SimulatorDisplayMetadata(
                width: 1_170,
                height: 2_532,
                orientation: .portrait,
                scale: 3
            )
        )
        let record = try source.uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 1,
            capturedAtMilliseconds: 1_000
        )

        let tab = try #require(record.element(ref: "e2"))
        #expect(tab.element.role == .tab)
        #expect(tab.element.actions.contains(.tap))
        #expect((0...1).contains(tab.activationPoint.x))
        #expect((0...1).contains(tab.activationPoint.y))

        let scrollView = try #require(record.element(ref: "e3")?.element)
        #expect(scrollView.role == .scrollView)
        #expect(scrollView.actions.contains(.swipeWithin))
    }

    private func snapshot(
        searchFocused: Bool = true
    ) -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [
                node(
                    id: "0",
                    role: "Application",
                    label: "Settings",
                    frame: SimulatorRect(x: 0, y: 0, width: 402, height: 874),
                    children: [
                        node(
                            id: "0.0",
                            identifier: "settings.general",
                            role: "AXButton",
                            label: "General",
                            frame: SimulatorRect(x: 16, y: 120, width: 370, height: 52),
                            focused: false
                        ),
                        node(
                            id: "0.1",
                            identifier: "settings.search",
                            role: "Search field",
                            label: "Search",
                            value: "Search settings",
                            frame: SimulatorRect(x: 16, y: 60, width: 370, height: 44),
                            focused: searchFocused
                        ),
                        node(
                            id: "0.2",
                            role: "Scroll view",
                            label: "Settings list",
                            frame: SimulatorRect(x: 0, y: 110, width: 402, height: 700)
                        ),
                    ]
                ),
            ],
            display: SimulatorDisplayMetadata(
                width: 1_206,
                height: 2_622,
                orientation: .portrait,
                scale: 3
            )
        )
    }

    private func node(
        id: String,
        identifier: String? = nil,
        role: String,
        label: String,
        value: String? = nil,
        frame: SimulatorRect,
        enabled: Bool = true,
        focused: Bool? = nil,
        children: [SimulatorAccessibilityNode] = []
    ) -> SimulatorAccessibilityNode {
        SimulatorAccessibilityNode(
            id: id,
            identifier: identifier,
            role: role,
            label: label,
            value: value,
            frame: frame,
            isEnabled: enabled,
            isFocused: focused,
            children: children
        )
    }
}
