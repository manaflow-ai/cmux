import Foundation
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
        #expect(
            record.snapshot.elements.map(\.ref)
                == ["e7_1", "e7_2", "e7_3", "e7_4"]
        )

        let button = try #require(record.element(ref: "e7_2")?.element)
        #expect(button.identifier == "settings.general")
        #expect(button.role == .button)
        #expect(button.state.isEnabled)
        #expect(button.state.isFocused == false)
        #expect(button.actions == [.tap, .longPress, .touch])

        let textField = try #require(record.element(ref: "e7_3")?.element)
        #expect(textField.role == .textField)
        #expect(textField.state.isFocused == true)
        #expect(textField.actions.contains(.typeText))

        let list = try #require(record.element(ref: "e7_4")?.element)
        #expect(list.role == .scrollView)
        #expect(list.actions.contains(.swipeWithin))
        #expect(record.snapshot.actions.contains {
            $0.elementRef == "e7_3" && $0.action == .typeText
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

    @Test("Screen hashes ignore offscreen-only accessibility changes")
    func screenHashIgnoresOffscreenState() throws {
        func source(offscreenLabel: String, offscreenY: Double) -> SimulatorAccessibilitySnapshot {
            SimulatorAccessibilitySnapshot(
                roots: [node(
                    id: "0",
                    role: "Application",
                    label: "Example",
                    frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                    children: [
                        node(
                            id: "0.0",
                            role: "AXButton",
                            label: "Visible",
                            frame: SimulatorRect(x: 20, y: 100, width: 120, height: 44)
                        ),
                        node(
                            id: "0.1",
                            role: "StaticText",
                            label: offscreenLabel,
                            frame: SimulatorRect(
                                x: 20,
                                y: offscreenY,
                                width: 120,
                                height: 44
                            )
                        ),
                    ]
                )],
                display: SimulatorDisplayMetadata(
                    width: 1_170,
                    height: 2_532,
                    orientation: .portrait,
                    scale: 3
                )
            )
        }
        let first = try source(
            offscreenLabel: "Pending",
            offscreenY: 900
        ).uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 1,
            capturedAtMilliseconds: 1_000
        )
        let offscreenChanged = try source(
            offscreenLabel: "Complete",
            offscreenY: 900
        ).uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 2,
            capturedAtMilliseconds: 2_000
        )
        let becameVisible = try source(
            offscreenLabel: "Complete",
            offscreenY: 700
        ).uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 3,
            capturedAtMilliseconds: 3_000
        )

        #expect(first.snapshot.screenHash == offscreenChanged.snapshot.screenHash)
        #expect(first.snapshot.screenHash != becameVisible.snapshot.screenHash)
    }

    @Test("Text fields advertise typing only when they can be reidentified")
    func typeTextRequiresStableSelector() throws {
        let source = SimulatorAccessibilitySnapshot(
            roots: [node(
                id: "0",
                role: "Application",
                label: "Example",
                frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                children: [SimulatorAccessibilityNode(
                    id: "0.0",
                    role: "AXTextField",
                    label: nil,
                    value: nil,
                    frame: SimulatorRect(x: 20, y: 100, width: 200, height: 44),
                    isEnabled: true,
                    children: []
                )]
            )],
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
        let textField = try #require(record.snapshot.elements.first {
            $0.role == .textField
        })

        #expect(record.stableSelector(for: textField.ref) == nil)
        #expect(!textField.actions.contains(.typeText))
        #expect(!record.snapshot.actions.contains {
            $0.elementRef == textField.ref && $0.action == .typeText
        })
    }

    @Test("Text fields advertise typing only when their selector is unique")
    func typeTextRequiresUniqueSelector() throws {
        let source = SimulatorAccessibilitySnapshot(
            roots: [node(
                id: "0",
                role: "Application",
                label: "Example",
                frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                children: [
                    node(
                        id: "0.0",
                        role: "AXTextField",
                        label: "Name",
                        frame: SimulatorRect(x: 20, y: 100, width: 200, height: 44)
                    ),
                    node(
                        id: "0.1",
                        role: "AXTextField",
                        label: "Name",
                        frame: SimulatorRect(x: 20, y: 160, width: 200, height: 44)
                    ),
                ]
            )],
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
        let textFields = record.snapshot.elements.filter { $0.role == .textField }

        #expect(textFields.count == 2)
        #expect(textFields.allSatisfy { !$0.actions.contains(.typeText) })
        #expect(!record.snapshot.actions.contains { $0.action == .typeText })
    }

    @Test("Stable selectors prefer runtime identifiers and directional points stay bounded")
    func selectorsAndGesturePoints() throws {
        let record = try snapshot().uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 1,
            capturedAtMilliseconds: 1_000
        )

        let selector = try #require(record.stableSelector(for: "e1_2"))
        #expect(selector.identifier == "settings.general")
        #expect(selector.label == nil)

        let swipe = try #require(record.swipePoints(
            elementRef: "e1_4",
            direction: .up,
            distance: 1
        ))
        #expect(swipe.from.y > swipe.to.y)
        #expect((0...1).contains(swipe.from.x))
        #expect((0...1).contains(swipe.from.y))
        #expect((0...1).contains(swipe.to.x))
        #expect((0...1).contains(swipe.to.y))

        let drag = try #require(record.dragPoints(
            elementRef: "e1_2",
            direction: .right,
            distance: 0.5
        ))
        let dragTarget = try #require(record.element(ref: "e1_2"))
        #expect(drag.from == dragTarget.activationPoint)
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
        )).map(\.ref) == ["e1_2"])
        #expect(record.accessibilityInteractionTargets(
            label: "Search",
            identifier: nil,
            role: "text-field"
        ).map(\.element.ref) == ["e1_3"])
        #expect(record.accessibilityInteractionTargets(
            label: nil,
            identifier: "0.2",
            role: nil
        ).isEmpty)
        #expect(record.containingText("search").map(\.ref) == ["e1_3"])
        #expect(record.containingText("GENERAL").map(\.ref) == ["e1_2"])

        let repeated = [
            try #require(record.element(ref: "e1_2")?.element),
            try #require(record.element(ref: "e1_2")?.element),
        ]
        let distinct = repeated + [
            try #require(record.element(ref: "e1_3")?.element),
        ]
        #expect(record.candidatesShareMatchingText(repeated, containing: "general"))
        #expect(!record.candidatesShareMatchingText(distinct, containing: "e"))
    }

    @Test("Semantic queries exclude offscreen accessibility nodes")
    func semanticQueriesExcludeOffscreenNodes() throws {
        let source = SimulatorAccessibilitySnapshot(
            roots: [
                node(
                    id: "0",
                    role: "Application",
                    label: "Example",
                    frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                    children: [
                        node(
                            id: "0.0",
                            identifier: "visible.continue",
                            role: "AXButton",
                            label: "Continue",
                            frame: SimulatorRect(x: 20, y: 100, width: 120, height: 44)
                        ),
                        node(
                            id: "0.1",
                            identifier: "offscreen.continue",
                            role: "AXButton",
                            label: "Continue",
                            frame: SimulatorRect(x: 20, y: 900, width: 120, height: 44)
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

        #expect(record.matching(SimulatorUIAutomationSelector(
            label: "Continue",
            role: .button
        )).map(\.identifier) == ["visible.continue"])
        #expect(record.containingText("continue").map(\.identifier) == ["visible.continue"])
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

        let tab = try #require(record.element(ref: "e1_2"))
        #expect(tab.element.role == .tab)
        #expect(tab.element.actions.contains(.tap))
        #expect((0...1).contains(tab.activationPoint.x))
        #expect((0...1).contains(tab.activationPoint.y))

        let scrollView = try #require(record.element(ref: "e1_3")?.element)
        #expect(scrollView.role == .scrollView)
        #expect(scrollView.actions.contains(.swipeWithin))
    }

    @Test("Keyboard key descriptions override generic button roles")
    func keyboardKeyDescriptionOverridesButtonRole() throws {
        let source = SimulatorAccessibilitySnapshot(
            roots: [
                SimulatorAccessibilityNode(
                    id: "0",
                    identifier: "keyboard.delete",
                    role: "AXButton",
                    label: "delete",
                    value: nil,
                    roleDescription: "Keyboard key",
                    frame: SimulatorRect(x: 300, y: 700, width: 50, height: 50),
                    isEnabled: true,
                    children: []
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

        let key = try #require(record.element(ref: "e1_1")?.element)
        #expect(key.role == .keyboardKey)
        #expect(record.matching(SimulatorUIAutomationSelector(role: .keyboardKey)).map(\.ref) == ["e1_1"])
    }

    @Test("Nested content extending past a container infers one swipe target")
    func nestedOverflowInfersScrollableContainer() throws {
        let source = SimulatorAccessibilitySnapshot(
            roots: [
                node(
                    id: "0",
                    role: "Application",
                    label: "Example",
                    frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                    children: [
                        node(
                            id: "0.0",
                            role: "Group",
                            label: "Content",
                            frame: SimulatorRect(x: 0, y: 100, width: 390, height: 500),
                            children: [
                                node(
                                    id: "0.0.0",
                                    role: "Group",
                                    label: "Nested",
                                    frame: SimulatorRect(
                                        x: 0,
                                        y: 580,
                                        width: 390,
                                        height: 100
                                    )
                                ),
                            ]
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

        let container = try #require(record.element(ref: "e1_2")?.element)
        #expect(container.actions.contains(.swipeWithin))
    }

    @Test("Invalid element frames stay invisible and unactionable")
    func invalidFramesAreNotActionable() throws {
        let source = SimulatorAccessibilitySnapshot(
            roots: [
                node(
                    id: "0",
                    role: "Application",
                    label: "Example",
                    frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                    children: [
                        node(
                            id: "0.0",
                            role: "Button",
                            label: "Zero width",
                            frame: SimulatorRect(x: 20, y: 100, width: 0, height: 44)
                        ),
                        node(
                            id: "0.1",
                            role: "Button",
                            label: "Negative width",
                            frame: SimulatorRect(x: 20, y: 160, width: -10, height: 44)
                        ),
                        node(
                            id: "0.2",
                            role: "Button",
                            label: "Non-finite origin",
                            frame: SimulatorRect(
                                x: .nan,
                                y: .infinity,
                                width: 44,
                                height: 44
                            )
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

        for element in record.snapshot.elements.dropFirst() {
            #expect(!element.state.isVisible)
            #expect(element.actions.isEmpty)
            #expect(element.frame.x.isFinite)
            #expect(element.frame.y.isFinite)
            #expect(element.frame.width.isFinite)
            #expect(element.frame.height.isFinite)
        }
        _ = try JSONEncoder().encode(record.snapshot)
    }

    @Test("Duplicate refs retain the first lookup record without trapping")
    func duplicateRefsRetainFirstRecord() throws {
        let built = try snapshot().uiAutomationRecord(
            simulatorID: "SIM-1",
            sequence: 1,
            capturedAtMilliseconds: 1_000
        )
        let first = try #require(built.elementRecords.first)
        let duplicate = SimulatorUIAutomationElementRecord(
            element: first.element,
            node: first.node,
            path: "duplicate",
            activationPoint: SimulatorPoint(x: 0.9, y: 0.9),
            viewport: first.viewport,
            swipeFrame: first.swipeFrame
        )

        let record = SimulatorUIAutomationSnapshotRecord(
            snapshot: built.snapshot,
            elementRecords: [first, duplicate]
        )

        #expect(record.elementRecords.count == 2)
        #expect(record.element(ref: first.element.ref)?.path == first.path)
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
