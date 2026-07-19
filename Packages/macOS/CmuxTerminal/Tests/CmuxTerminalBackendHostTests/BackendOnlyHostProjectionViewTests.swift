import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite("Backend-only host projection view")
struct BackendOnlyHostProjectionViewTests {
    @Test("nested split geometry preserves canonical direction and ratio")
    func nestedSplitGeometryIsExact() throws {
        let fixture = ProjectionViewFixture()
        let layout = BackendOnlyProjectionLayout.split(
            direction: .right,
            ratio: 0.4,
            first: .pane(fixture.one.slotID),
            second: .split(
                direction: .down,
                ratio: 0.25,
                first: .pane(fixture.two.slotID),
                second: .pane(fixture.three.slotID)
            )
        )

        let geometry = BackendOnlyProjectionLayoutGeometry.resolve(
            layout: layout,
            in: CGSize(width: 1_000, height: 800),
            dividerThickness: 2
        )

        #expect(geometry.panes.map(\.slotID) == [
            fixture.one.slotID,
            fixture.two.slotID,
            fixture.three.slotID,
        ])
        #expect(try paneFrame(fixture.one.slotID, in: geometry) == CGRect(
            x: 0,
            y: 0,
            width: 400,
            height: 800
        ))
        #expect(try paneFrame(fixture.two.slotID, in: geometry) == CGRect(
            x: 400,
            y: 0,
            width: 600,
            height: 200
        ))
        #expect(try paneFrame(fixture.three.slotID, in: geometry) == CGRect(
            x: 400,
            y: 200,
            width: 600,
            height: 600
        ))
        #expect(geometry.dividers.map(\.direction) == [.right, .down])
        #expect(geometry.dividers.map(\.frame) == [
            CGRect(x: 399, y: 0, width: 2, height: 800),
            CGRect(x: 400, y: 199, width: 600, height: 2),
        ])
    }

    @Test("view model binds runtimes by exact slot identity without positional fallback")
    func viewModelUsesExactSlotIdentity() throws {
        let fixture = ProjectionViewFixture()
        let runtimeOne = ProjectionViewRuntime(selection: fixture.one.selection)
        let runtimeTwo = ProjectionViewRuntime(selection: fixture.two.selection)
        let snapshot = fixture.snapshot(
            panes: [fixture.one, fixture.two],
            runtimeSlots: [
                (fixture.two, runtimeTwo),
                (fixture.one, runtimeOne),
            ],
            active: fixture.two,
            layout: .split(
                direction: .right,
                ratio: 0.5,
                first: .pane(fixture.one.slotID),
                second: .pane(fixture.two.slotID)
            )
        )

        let viewModel = BackendOnlyHostProjectionViewModel(snapshot: snapshot)
        let one = try #require(viewModel.pane(for: fixture.one.slotID))
        let two = try #require(viewModel.pane(for: fixture.two.slotID))

        #expect(one.runtime === runtimeOne)
        #expect(two.runtime === runtimeTwo)
        #expect(one.tabs.map(\.surfaceID) == fixture.one.descriptor.tabs.map(\.surfaceID))
        #expect(viewModel.activeSlotID == fixture.two.slotID)
        #expect(viewModel.pane(for: fixture.three.slotID) == nil)
    }

    @Test("pane and tab clicks share one ordered absolute-intent action path")
    func paneAndTabClicksShareActionPath() async throws {
        let fixture = ProjectionViewFixture()
        let recorder = ProjectionFocusActionRecorder(
            fences: [
                fixture.fence(topology: 2, projection: 2),
                fixture.fence(topology: 3, projection: 3),
            ]
        )
        let binding = BackendOnlyHostFocusBinding(submitAction: recorder.submit)
        let oneFocus = ProjectionFocusCounter()
        let twoFocus = ProjectionFocusCounter()
        #expect(binding.register(
            slotID: fixture.one.slotID,
            content: .terminal(selectedSurfaceID: fixture.one.selection.surfaceID),
            requestFirstResponder: oneFocus.request
        ))
        #expect(binding.register(
            slotID: fixture.two.slotID,
            content: .terminal(selectedSurfaceID: fixture.two.selection.surfaceID),
            requestFirstResponder: twoFocus.request
        ))
        #expect(binding.installAuthoritativeActiveSlot(
            fixture.one.slotID,
            fence: fixture.fence(topology: 1, projection: 1)
        ))

        let otherTab = SurfaceID(rawValue: projectionFixtureUUID(10_099))
        #expect(await binding.pointerClick(
            slotID: fixture.two.slotID,
            desiredSurfaceID: otherTab
        ) == .applied)
        #expect(await binding.pointerClick(
            slotID: fixture.one.slotID,
            desiredSurfaceID: fixture.one.selection.surfaceID
        ) == .applied)

        let actions = recorder.actions
        #expect(actions.count == 2)
        #expect(actions[0].intents == [
            .selectSurface(
                workspaceID: fixture.two.slotID.workspaceID,
                screenID: fixture.two.slotID.screenID,
                paneID: fixture.two.slotID.paneID,
                surfaceID: otherTab
            ),
            .activatePane(
                workspaceID: fixture.two.slotID.workspaceID,
                screenID: fixture.two.slotID.screenID,
                paneID: fixture.two.slotID.paneID
            ),
        ])
        #expect(actions[1].intents == [
            .activatePane(
                workspaceID: fixture.one.slotID.workspaceID,
                screenID: fixture.one.slotID.screenID,
                paneID: fixture.one.slotID.paneID
            ),
        ])
        #expect(binding.activeSlotID == fixture.one.slotID)
    }

    @Test("key-window binding focuses only the fenced daemon-active terminal")
    func keyWindowBindingUsesExactAuthority() {
        let fixture = ProjectionViewFixture()
        let recorder = ProjectionFocusActionRecorder(fences: [])
        let binding = BackendOnlyHostFocusBinding(submitAction: recorder.submit)
        let oneFocus = ProjectionFocusCounter()
        let twoFocus = ProjectionFocusCounter()
        binding.register(
            slotID: fixture.one.slotID,
            content: .terminal(selectedSurfaceID: fixture.one.selection.surfaceID),
            requestFirstResponder: oneFocus.request
        )
        binding.register(
            slotID: fixture.two.slotID,
            content: .terminal(selectedSurfaceID: fixture.two.selection.surfaceID),
            requestFirstResponder: twoFocus.request
        )
        #expect(binding.installAuthoritativeActiveSlot(
            fixture.two.slotID,
            fence: fixture.fence(topology: 1, projection: 1)
        ))

        binding.setWindowKey(true)
        #expect(oneFocus.count == 0)
        #expect(twoFocus.count == 1)
        #expect(binding.activeSlotID == fixture.two.slotID)

        binding.unregister(slotID: fixture.two.slotID)
        binding.setWindowKey(false)
        binding.setWindowKey(true)
        #expect(oneFocus.count == 0)
        #expect(twoFocus.count == 1)
    }

    private func paneFrame(
        _ slotID: BackendOnlyProjectionSlotID,
        in geometry: BackendOnlyProjectionLayoutGeometry.Result
    ) throws -> CGRect {
        try #require(geometry.panes.first { $0.slotID == slotID }).frame
    }
}

@MainActor
private final class ProjectionViewRuntime: BackendOnlyHostRuntimeLifecycle {
    let selection: BackendOnlyTerminalSelection

    init(selection: BackendOnlyTerminalSelection) {
        self.selection = selection
    }

    func shutdown() async {}
}

@MainActor
private final class ProjectionFocusCounter {
    private(set) var count = 0

    func request() -> Bool {
        count += 1
        return true
    }
}

@MainActor
private final class ProjectionFocusActionRecorder {
    private var remainingFences: [BackendOnlyProjectionRuntimeFence]
    private(set) var actions: [BackendOnlyFocusAction] = []

    init(fences: [BackendOnlyProjectionRuntimeFence]) {
        remainingFences = fences
    }

    func submit(_ action: BackendOnlyFocusAction) async -> BackendOnlyFocusActionReceipt {
        actions.append(action)
        let fence = remainingFences.removeFirst()
        return BackendOnlyFocusActionReceipt(
            actionID: action.actionID,
            fence: fence,
            outcome: .applied,
            activeSlotID: action.targetSlotID,
            selectedSurfaceID: action.desiredSurfaceID
        )
    }
}

@MainActor
private struct ProjectionViewFixture {
    struct Pane {
        let descriptor: BackendOnlyProjectionPaneDescriptor
        let selection: BackendOnlyTerminalSelection

        var slotID: BackendOnlyProjectionSlotID { descriptor.slotID }
    }

    let logicalPresentationID = projectionFixtureUUID(1)
    let workspaceID = WorkspaceID(rawValue: projectionFixtureUUID(2))
    let screenID = ScreenID(rawValue: projectionFixtureUUID(3))
    let authority = BackendAuthority(
        daemonInstanceID: DaemonInstanceID(rawValue: projectionFixtureUUID(4)),
        sessionID: SessionID(rawValue: projectionFixtureUUID(5))
    )
    let one: Pane
    let two: Pane
    let three: Pane

    init() {
        one = Self.pane(
            logicalPresentationID: logicalPresentationID,
            workspaceID: workspaceID,
            screenID: screenID,
            pane: 1,
            surfaces: [11, 12],
            selectedSurface: 11,
            active: false
        )
        two = Self.pane(
            logicalPresentationID: logicalPresentationID,
            workspaceID: workspaceID,
            screenID: screenID,
            pane: 2,
            surfaces: [21],
            selectedSurface: 21,
            active: true
        )
        three = Self.pane(
            logicalPresentationID: logicalPresentationID,
            workspaceID: workspaceID,
            screenID: screenID,
            pane: 3,
            surfaces: [31],
            selectedSurface: 31,
            active: false
        )
    }

    func fence(
        topology: UInt64,
        projection: UInt64
    ) -> BackendOnlyProjectionRuntimeFence {
        BackendOnlyProjectionRuntimeFence(
            connectionGeneration: 1,
            authority: authority,
            topologyRevision: topology,
            logicalPresentationID: logicalPresentationID,
            projectionGeneration: projection
        )
    }

    func snapshot(
        panes: [Pane],
        runtimeSlots: [(Pane, (any BackendOnlyHostRuntimeLifecycle)?)],
        active: Pane,
        layout: BackendOnlyProjectionLayout
    ) -> BackendOnlyProjectionRuntimeSnapshot {
        BackendOnlyProjectionRuntimeSnapshot(
            fence: fence(topology: 1, projection: 1),
            plan: BackendOnlyProjectionPlan(
                logicalPresentationID: logicalPresentationID,
                workspaceID: workspaceID,
                numericWorkspaceID: 1,
                workspaceName: "workspace",
                screenID: screenID,
                numericScreenID: 1,
                screenName: "screen",
                activePaneID: active.descriptor.paneID,
                zoomedPaneID: nil,
                layout: layout,
                panes: panes.map(\.descriptor),
                metrics: BackendOnlyProjectionPlannerMetrics(
                    visibleLeafCount: panes.count,
                    topologyWorkspaceIndexVisits: 1,
                    navigationWorkspaceIndexVisits: 1,
                    selectedWorkspaceScreenIndexVisits: 1,
                    selectedNavigationScreenIndexVisits: 1,
                    selectedScreenPaneIndexVisits: panes.count,
                    selectedNavigationPaneIndexVisits: panes.count,
                    visibleLeafCountNodeVisits: max(1, panes.count * 2 - 1),
                    materializedLayoutNodeVisits: max(1, panes.count * 2 - 1),
                    tabMetadataVisits: panes.reduce(0) { $0 + $1.descriptor.tabs.count }
                )
            ),
            slots: runtimeSlots.map {
                BackendOnlyProjectionRuntimeSlot(
                    descriptor: $0.0.descriptor,
                    runtime: $0.1
                )
            },
            activeSlotID: active.slotID
        )
    }

    private static func pane(
        logicalPresentationID: UUID,
        workspaceID: WorkspaceID,
        screenID: ScreenID,
        pane: UInt64,
        surfaces: [UInt64],
        selectedSurface: UInt64,
        active: Bool
    ) -> Pane {
        let paneID = PaneID(rawValue: projectionFixtureUUID(1_000 + pane))
        let selectedSurfaceID = SurfaceID(
            rawValue: projectionFixtureUUID(10_000 + selectedSurface)
        )
        let selection = BackendOnlyTerminalSelection(
            workspaceID: workspaceID,
            screenID: screenID,
            paneID: paneID,
            surfaceID: selectedSurfaceID,
            numericSurfaceID: selectedSurface
        )
        let slotID = BackendOnlyProjectionSlotID(
            logicalPresentationID: logicalPresentationID,
            workspaceID: workspaceID,
            screenID: screenID,
            paneID: paneID
        )
        let tabs = surfaces.map { surface in
            BackendOnlyProjectionTabMetadata(
                surfaceID: SurfaceID(
                    rawValue: projectionFixtureUUID(10_000 + surface)
                ),
                numericSurfaceID: surface,
                kind: "terminal",
                name: "tab-\(surface)",
                browserEndpoint: nil,
                externalTerminalProvenance: nil,
                isSelected: surface == selectedSurface
            )
        }
        return Pane(
            descriptor: BackendOnlyProjectionPaneDescriptor(
                slotID: slotID,
                paneID: paneID,
                numericPaneID: pane,
                paneName: "pane-\(pane)",
                isActive: active,
                tabs: tabs,
                content: .terminal(selection)
            ),
            selection: selection
        )
    }
}

private func projectionFixtureUUID(_ value: UInt64) -> UUID {
    UUID(uuid: (
        UInt8((value >> 56) & 0xff),
        UInt8((value >> 48) & 0xff),
        UInt8((value >> 40) & 0xff),
        UInt8((value >> 32) & 0xff),
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
        0, 0, 0, 0, 0, 0, 0, 1
    ))
}
