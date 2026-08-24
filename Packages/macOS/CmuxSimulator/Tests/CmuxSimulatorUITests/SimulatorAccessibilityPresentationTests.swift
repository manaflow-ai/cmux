import CoreGraphics
import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@MainActor
@Suite("Simulator accessibility presentation")
struct SimulatorAccessibilityPresentationTests {
    @Test("Presentation cache preserves every bounded node past the first page")
    func preservesNodesBeyondFirstPage() {
        let children = (0..<75).map { index in
            SimulatorAccessibilityNode(
                id: "child-\(index)",
                role: "Button",
                label: "Child \(index)",
                value: nil,
                frame: nil,
                isEnabled: true,
                children: []
            )
        }
        let root = SimulatorAccessibilityNode(
            id: "root",
            role: "Application",
            label: nil,
            value: nil,
            frame: nil,
            isEnabled: true,
            children: children
        )

        let rows = simulatorAccessibilityPresentationRows([root])

        #expect(rows.count == 76)
        #expect(rows[50].node.id == "child-49")
        #expect(rows.last?.node.id == "child-74")
        #expect(rows.last?.depth == 1)
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test("Presentation cache remains capped if a malformed snapshot exceeds the worker contract")
    func defensivePresentationCap() {
        let roots = (0..<600).map { index in
            SimulatorAccessibilityNode(
                id: "node-\(index)", role: nil, label: nil, value: nil,
                frame: nil, isEnabled: nil, children: []
            )
        }

        #expect(simulatorAccessibilityPresentationRows(roots).count == 500)
    }

    @Test("Overlay maps every framed node through the largest accessibility container")
    func overlayFrameMapping() {
        let root = SimulatorAccessibilityNode(
            id: "root", role: "Application", label: nil, value: nil,
            frame: SimulatorRect(x: 10, y: 20, width: 200, height: 400),
            isEnabled: true,
            children: [SimulatorAccessibilityNode(
                id: "button", role: "Button", label: "Continue", value: nil,
                frame: SimulatorRect(x: 60, y: 120, width: 50, height: 40),
                isEnabled: true, children: []
            )]
        )
        let rows = simulatorAccessibilityPresentationRows([root])
        let frames = simulatorAccessibilityOverlayFrames(
            rows: rows,
            screenRect: CGRect(x: 20, y: 30, width: 100, height: 200)
        )

        #expect(frames.count == 2)
        #expect(frames[0].rect == CGRect(x: 20, y: 30, width: 100, height: 200))
        #expect(frames[1].rect == CGRect(x: 45, y: 80, width: 25, height: 20))
    }

    @Test("Live overlay pauses while hidden and joins polling during close")
    func liveOverlayPollingLifecycle() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let sleeper = AccessibilityOverlaySleeper()
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            webInspectorSleeper: sleeper
        )

        coordinator.setAccessibilityOverlayVisibility(true)
        coordinator.setAccessibilityOverlayEnabled(true)
        await Self.eventually {
            let readCount = await Self.accessibilityReadCount(client: client)
            let counts = await sleeper.counts()
            return readCount == 1 && counts.starts == 1
        }
        #expect(!coordinator.isPerformingControlAction)

        coordinator.setAccessibilityOverlayVisibility(false)
        await Self.eventually {
            let counts = await sleeper.counts()
            return counts.cancellations == 1
        }
        #expect(coordinator.accessibilityOverlayEnabled)
        let hiddenReadCount = await Self.accessibilityReadCount(client: client)
        #expect(hiddenReadCount == 1)

        coordinator.setAccessibilityOverlayVisibility(true)
        await Self.eventually {
            let readCount = await Self.accessibilityReadCount(client: client)
            let counts = await sleeper.counts()
            return readCount == 2 && counts.starts == 2
        }
        await coordinator.close()

        let counts = await sleeper.counts()
        let stopCount = await client.stopCount()
        #expect(counts.cancellations == 2)
        #expect(stopCount == 1)
        #expect(!coordinator.accessibilityOverlayEnabled)
    }

    @Test("Overlay selection is host-only and clears with its toggle")
    func overlaySelectionLifecycle() async {
        let coordinator = SimulatorPaneCoordinator(client: SimulatorPaneClientSpy(devices: []))
        let node = SimulatorAccessibilityNode(
            id: "button", role: "Button", label: "Continue", value: nil,
            frame: nil, isEnabled: true, children: []
        )

        coordinator.setAccessibilityOverlayEnabled(true)
        coordinator.selectAccessibilityOverlayNode(node)
        #expect(coordinator.accessibilityOverlaySelectedNodeID == node.id)

        coordinator.setAccessibilityOverlayEnabled(false)
        #expect(coordinator.accessibilityOverlaySelectedNodeID == nil)
        await coordinator.close()
    }

    private static func accessibilityReadCount(client: SimulatorPaneClientSpy) async -> Int {
        await client.actions().reduce(into: 0) { count, action in
            if case .readAccessibility = action { count += 1 }
        }
    }

    private static func eventually(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }
}
