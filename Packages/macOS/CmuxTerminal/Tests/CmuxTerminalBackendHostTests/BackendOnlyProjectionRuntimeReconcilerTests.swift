import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@Suite("Backend-only projection runtime reconciler")
@MainActor
struct BackendOnlyProjectionRuntimeReconcilerTests {
    @Test("unchanged terminal selection reuses the exact runtime")
    func unchangedTerminalSelectionReusesRuntime() async throws {
        let fixture = try Fixture()
        let terminal = fixture.terminalPane(pane: 1, surface: 101, active: true)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 1),
            plan: fixture.plan([terminal])
        )
        let original = try fixture.runtime(in: 0)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 2, projection: 2),
            plan: fixture.plan([terminal])
        )

        #expect(try fixture.runtime(in: 0) === original)
        #expect(fixture.factory.attempts == [terminal.terminalSelection])
        #expect(original.shutdownCount == 0)
    }

    @Test("tab switch replaces within the stable pane slot")
    func tabSwitchReplacesInPlace() async throws {
        let fixture = try Fixture()
        let first = fixture.terminalPane(pane: 1, surface: 101, active: true)
        let second = fixture.terminalPane(pane: 1, surface: 102, active: true)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 1),
            plan: fixture.plan([first])
        )
        let original = try fixture.runtime(in: 0)
        let originalSlot = try #require(fixture.reconciler.snapshot?.slots.first?.slotID)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 2),
            plan: fixture.plan([second])
        )
        let replacement = try fixture.runtime(in: 0)

        #expect(replacement !== original)
        #expect(fixture.reconciler.snapshot?.slots.first?.slotID == originalSlot)
        #expect(original.shutdownCount == 1)
        #expect(replacement.shutdownCount == 0)
        #expect(fixture.factory.attempts == [
            first.terminalSelection,
            second.terminalSelection,
        ])
    }

    @Test("split add remove and reorder preserve leaf order and exact ownership")
    func splitAddRemoveAndReorder() async throws {
        let fixture = try Fixture()
        let one = fixture.terminalPane(pane: 1, surface: 101, active: true)
        let two = fixture.terminalPane(pane: 2, surface: 201)
        let three = fixture.terminalPane(pane: 3, surface: 301)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 1),
            plan: fixture.plan([one, two])
        )
        let runtimeOne = try fixture.runtime(in: 0)
        let runtimeTwo = try fixture.runtime(in: 1)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 2, projection: 2),
            plan: fixture.plan([two, one, three])
        )
        let runtimeThree = try fixture.runtime(in: 2)

        #expect(try fixture.runtime(in: 0) === runtimeTwo)
        #expect(try fixture.runtime(in: 1) === runtimeOne)
        #expect(fixture.factory.attempts == [
            one.terminalSelection,
            two.terminalSelection,
            three.terminalSelection,
        ])

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 3, projection: 3),
            plan: fixture.plan([three, one])
        )

        #expect(try fixture.runtime(in: 0) === runtimeThree)
        #expect(try fixture.runtime(in: 1) === runtimeOne)
        #expect(runtimeOne.shutdownCount == 0)
        #expect(runtimeTwo.shutdownCount == 1)
        #expect(runtimeThree.shutdownCount == 0)
    }

    @Test("placeholder transitions own no runtime and retire terminal once")
    func placeholderTransitionsOwnNoRuntime() async throws {
        let fixture = try Fixture()
        let terminal = fixture.terminalPane(pane: 1, surface: 101, active: true)
        let browser = fixture.browserPane(pane: 1, surface: 102, active: true)
        let unsupported = fixture.unsupportedPane(pane: 1, surface: 103, active: true)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 1),
            plan: fixture.plan([terminal])
        )
        let original = try fixture.runtime(in: 0)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 2),
            plan: fixture.plan([browser])
        )
        #expect(fixture.reconciler.snapshot?.slots.first?.runtime == nil)
        #expect(original.shutdownCount == 1)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 3),
            plan: fixture.plan([unsupported])
        )
        #expect(fixture.reconciler.snapshot?.slots.first?.runtime == nil)
        #expect(fixture.factory.attempts == [terminal.terminalSelection])
        #expect(original.shutdownCount == 1)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 4),
            plan: fixture.plan([terminal])
        )
        #expect(fixture.reconciler.snapshot?.slots.first?.runtime != nil)
        #expect(fixture.factory.attempts == [
            terminal.terminalSelection,
            terminal.terminalSelection,
        ])
    }

    @Test("construction failure rolls back publication and disposes candidates")
    func constructionFailureRollsBackAtomically() async throws {
        let fixture = try Fixture()
        let one = fixture.terminalPane(pane: 1, surface: 101, active: true)
        let two = fixture.terminalPane(pane: 2, surface: 201)
        let three = fixture.terminalPane(pane: 3, surface: 301)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 1),
            plan: fixture.plan([one])
        )
        let publishedBeforeFailure = try #require(fixture.reconciler.snapshot)
        let original = try fixture.runtime(in: 0)
        fixture.factory.failingSurface = three.terminalSelection.surfaceID

        do {
            _ = try await fixture.reconciler.apply(
                session: fixture.firstSession,
                fence: fixture.fence(topology: 2, projection: 2),
                plan: fixture.plan([one, two, three])
            )
            Issue.record("expected construction failure")
        } catch let error as BackendOnlyProjectionRuntimeReconcilerError {
            #expect(error == .runtimeConstructionFailed(slotID: three.slotID))
        }

        #expect(fixture.reconciler.snapshot?.plan == publishedBeforeFailure.plan)
        #expect(try fixture.runtime(in: 0) === original)
        #expect(original.shutdownCount == 0)
        let candidate = try #require(fixture.factory.created.first {
            $0.selection.surfaceID == two.terminalSelection.surfaceID
        })
        #expect(candidate.shutdownCount == 1)
        #expect(fixture.factory.liveRuntimes.map(\.selection.surfaceID) == [
            one.terminalSelection.surfaceID,
        ])
    }

    @Test("stale topology or projection generation cannot replace publication")
    func staleGenerationIsRejected() async throws {
        let fixture = try Fixture()
        let current = fixture.terminalPane(pane: 1, surface: 101, active: true)
        let stale = fixture.terminalPane(pane: 1, surface: 102, active: true)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 5, projection: 7),
            plan: fixture.plan([current])
        )
        let original = try fixture.runtime(in: 0)

        await #expect(throws: BackendOnlyProjectionRuntimeReconcilerError.staleFence) {
            _ = try await fixture.reconciler.apply(
                session: fixture.firstSession,
                fence: fixture.fence(topology: 4, projection: 8),
                plan: fixture.plan([stale])
            )
        }
        await #expect(throws: BackendOnlyProjectionRuntimeReconcilerError.staleFence) {
            _ = try await fixture.reconciler.apply(
                session: fixture.firstSession,
                fence: fixture.fence(topology: 6, projection: 6),
                plan: fixture.plan([stale])
            )
        }

        #expect(try fixture.runtime(in: 0) === original)
        #expect(fixture.factory.attempts == [current.terminalSelection])
        #expect(original.shutdownCount == 0)
    }

    @Test("connection generation fences session object and daemon authority")
    func connectionGenerationFencesSessionAndAuthority() async throws {
        let fixture = try Fixture()
        let terminal = fixture.terminalPane(pane: 1, surface: 101, active: true)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(connection: 1, topology: 1, projection: 1),
            plan: fixture.plan([terminal])
        )
        let original = try fixture.runtime(in: 0)

        await #expect(
            throws: BackendOnlyProjectionRuntimeReconcilerError.sessionObjectMismatch
        ) {
            _ = try await fixture.reconciler.apply(
                session: fixture.secondSession,
                fence: fixture.fence(connection: 1, topology: 2, projection: 2),
                plan: fixture.plan([terminal])
            )
        }

        _ = try await fixture.reconciler.apply(
            session: fixture.secondSession,
            fence: fixture.fence(
                connection: 2,
                authority: fixture.secondAuthority,
                topology: 1,
                projection: 1
            ),
            plan: fixture.plan([terminal])
        )

        #expect(try fixture.runtime(in: 0) !== original)
        #expect(original.shutdownCount == 1)
    }

    @Test("active pane is immutable data and does not trigger focus side effects")
    func activePaneIsDataOnly() async throws {
        let fixture = try Fixture()
        let one = fixture.terminalPane(pane: 1, surface: 101)
        let two = fixture.terminalPane(pane: 2, surface: 201, active: true)

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 1),
            plan: fixture.plan([one, two])
        )

        #expect(fixture.reconciler.snapshot?.activeSlotID == two.slotID)
        #expect(fixture.factory.created.allSatisfy { $0.focusMutationCount == 0 })
    }

    @Test("256 terminal candidates are created in deterministic leaf order")
    func maximumVisibleSlotsAreBoundedAndOrdered() async throws {
        let fixture = try Fixture()
        let panes = (1 ... 256).map {
            fixture.terminalPane(
                pane: UInt64($0),
                surface: UInt64(10_000 + $0),
                active: $0 == 1
            )
        }

        _ = try await fixture.reconciler.apply(
            session: fixture.firstSession,
            fence: fixture.fence(topology: 1, projection: 1),
            plan: fixture.plan(panes)
        )

        #expect(fixture.factory.attempts == panes.map(\.terminalSelection))
        #expect(fixture.reconciler.snapshot?.slots.map(\.slotID) == panes.map(\.slotID))

        let tooMany = panes + [
            fixture.terminalPane(pane: 257, surface: 10_257),
        ]
        await #expect(
            throws: BackendOnlyProjectionRuntimeReconcilerError.visibleSlotLimitExceeded(
                actual: 257,
                maximum: 256
            )
        ) {
            _ = try await fixture.reconciler.apply(
                session: fixture.firstSession,
                fence: fixture.fence(topology: 2, projection: 2),
                plan: fixture.plan(tooMany)
            )
        }
        #expect(fixture.factory.attempts.count == 256)
        #expect(fixture.reconciler.snapshot?.slots.count == 256)
    }

    @Test("layout and descriptor slot sets must match exactly")
    func layoutAndDescriptorSlotsMustMatch() async throws {
        let fixture = try Fixture()
        let one = fixture.terminalPane(pane: 1, surface: 101, active: true)
        let two = fixture.terminalPane(pane: 2, surface: 201)
        let invalid = fixture.plan([one, two], layoutPanes: [one])

        await #expect(
            throws: BackendOnlyProjectionRuntimeReconcilerError.layoutSlotSetMismatch
        ) {
            _ = try await fixture.reconciler.apply(
                session: fixture.firstSession,
                fence: fixture.fence(topology: 1, projection: 1),
                plan: invalid
            )
        }
        #expect(fixture.factory.attempts.isEmpty)
        #expect(fixture.reconciler.snapshot == nil)
    }
}

@MainActor
private final class Fixture {
    struct Pane {
        let descriptor: BackendOnlyProjectionPaneDescriptor
        let terminalSelection: BackendOnlyTerminalSelection

        var slotID: BackendOnlyProjectionSlotID { descriptor.slotID }
    }

    let logicalPresentationID = fixtureUUID(1)
    let workspaceID = WorkspaceID(rawValue: fixtureUUID(2))
    let screenID = ScreenID(rawValue: fixtureUUID(3))
    let firstAuthority = BackendAuthority(
        daemonInstanceID: DaemonInstanceID(rawValue: fixtureUUID(4)),
        sessionID: SessionID(rawValue: fixtureUUID(5))
    )
    let secondAuthority = BackendAuthority(
        daemonInstanceID: DaemonInstanceID(rawValue: fixtureUUID(6)),
        sessionID: SessionID(rawValue: fixtureUUID(7))
    )
    let firstSession: BackendCanonicalSession
    let secondSession: BackendCanonicalSession
    let factory = FakeRuntimeFactory()
    let reconciler: BackendOnlyProjectionRuntimeReconciler

    init() throws {
        firstSession = try makeFixtureSession(number: 1)
        secondSession = try makeFixtureSession(number: 2)
        reconciler = BackendOnlyProjectionRuntimeReconciler(factory: factory.makeRuntime)
    }

    func fence(
        connection: UInt64 = 1,
        authority: BackendAuthority? = nil,
        topology: UInt64,
        projection: UInt64
    ) -> BackendOnlyProjectionRuntimeFence {
        BackendOnlyProjectionRuntimeFence(
            connectionGeneration: connection,
            authority: authority ?? firstAuthority,
            topologyRevision: topology,
            logicalPresentationID: logicalPresentationID,
            projectionGeneration: projection
        )
    }

    func terminalPane(
        pane: UInt64,
        surface: UInt64,
        active: Bool = false
    ) -> Pane {
        let selection = terminalSelection(pane: pane, surface: surface)
        return Pane(
            descriptor: descriptor(
                pane: pane,
                surface: surface,
                active: active,
                content: .terminal(selection)
            ),
            terminalSelection: selection
        )
    }

    func browserPane(
        pane: UInt64,
        surface: UInt64,
        active: Bool = false
    ) -> Pane {
        let selection = terminalSelection(pane: pane, surface: surface)
        return Pane(
            descriptor: descriptor(
                pane: pane,
                surface: surface,
                active: active,
                content: .browserPlaceholder(
                    surfaceID: selection.surfaceID,
                    numericSurfaceID: surface,
                    endpoint: CanonicalBrowserEndpoint(
                        transport: .frontendNativeV1,
                        source: .launched
                    )
                )
            ),
            terminalSelection: selection
        )
    }

    func unsupportedPane(
        pane: UInt64,
        surface: UInt64,
        active: Bool = false
    ) -> Pane {
        let selection = terminalSelection(pane: pane, surface: surface)
        return Pane(
            descriptor: descriptor(
                pane: pane,
                surface: surface,
                active: active,
                content: .unsupportedPlaceholder(
                    surfaceID: selection.surfaceID,
                    numericSurfaceID: surface,
                    kind: "markdown"
                )
            ),
            terminalSelection: selection
        )
    }

    func plan(
        _ panes: [Pane],
        layoutPanes: [Pane]? = nil
    ) -> BackendOnlyProjectionPlan {
        let active = panes.first(where: { $0.descriptor.isActive }) ?? panes[0]
        let layoutSlots = (layoutPanes ?? panes).map(\.slotID)
        return BackendOnlyProjectionPlan(
            logicalPresentationID: logicalPresentationID,
            workspaceID: workspaceID,
            numericWorkspaceID: 2,
            workspaceName: "workspace",
            screenID: screenID,
            numericScreenID: 3,
            screenName: "screen",
            activePaneID: active.descriptor.paneID,
            zoomedPaneID: nil,
            layout: balancedLayout(layoutSlots),
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
                tabMetadataVisits: panes.count
            )
        )
    }

    func runtime(in index: Int) throws -> FakeRuntime {
        try #require(reconciler.snapshot?.slots[index].runtime as? FakeRuntime)
    }

    private func descriptor(
        pane: UInt64,
        surface: UInt64,
        active: Bool,
        content: BackendOnlyProjectionPaneContent
    ) -> BackendOnlyProjectionPaneDescriptor {
        let paneID = PaneID(rawValue: fixtureUUID(1_000 + pane))
        let surfaceID = SurfaceID(rawValue: fixtureUUID(10_000 + surface))
        return BackendOnlyProjectionPaneDescriptor(
            slotID: BackendOnlyProjectionSlotID(
                logicalPresentationID: logicalPresentationID,
                workspaceID: workspaceID,
                screenID: screenID,
                paneID: paneID
            ),
            paneID: paneID,
            numericPaneID: pane,
            paneName: nil,
            isActive: active,
            tabs: [
                BackendOnlyProjectionTabMetadata(
                    surfaceID: surfaceID,
                    numericSurfaceID: surface,
                    kind: content.kindForFixture,
                    name: nil,
                    browserEndpoint: nil,
                    externalTerminalProvenance: nil,
                    isSelected: true
                ),
            ],
            content: content
        )
    }

    private func terminalSelection(
        pane: UInt64,
        surface: UInt64
    ) -> BackendOnlyTerminalSelection {
        BackendOnlyTerminalSelection(
            workspaceID: workspaceID,
            screenID: screenID,
            paneID: PaneID(rawValue: fixtureUUID(1_000 + pane)),
            surfaceID: SurfaceID(rawValue: fixtureUUID(10_000 + surface)),
            numericSurfaceID: surface
        )
    }
}

@MainActor
private final class FakeRuntimeFactory {
    var attempts: [BackendOnlyTerminalSelection] = []
    var created: [FakeRuntime] = []
    var failingSurface: SurfaceID?

    var liveRuntimes: [FakeRuntime] {
        created.filter { $0.shutdownCount == 0 }
    }

    func makeRuntime(
        session _: BackendCanonicalSession,
        selection: BackendOnlyTerminalSelection
    ) async throws -> any BackendOnlyHostRuntimeLifecycle {
        attempts.append(selection)
        if selection.surfaceID == failingSurface {
            throw FakeRuntimeFactoryError.requestedFailure
        }
        let runtime = FakeRuntime(selection: selection)
        created.append(runtime)
        return runtime
    }
}

@MainActor
private final class FakeRuntime: BackendOnlyHostRuntimeLifecycle {
    let selection: BackendOnlyTerminalSelection
    private(set) var shutdownCount = 0
    private(set) var focusMutationCount = 0

    init(selection: BackendOnlyTerminalSelection) {
        self.selection = selection
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private enum FakeRuntimeFactoryError: Error {
    case requestedFailure
}

private actor ReconcilerInertTransport: BackendPeerIdentityTransport {
    private enum Failure: Error {
        case unavailable
    }

    func connect() async throws { throw Failure.unavailable }
    func send(_ message: Data) async throws { throw Failure.unavailable }
    func receive() async throws -> Data { throw Failure.unavailable }
    func peerIdentity() async throws -> BackendPeerIdentity { throw Failure.unavailable }
    func close() async {}
}

private func makeFixtureSession(number: UInt64) throws -> BackendCanonicalSession {
    guard let registration = BackendClientRegistrationIdentity(
        clientUUID: fixtureUUID(100 + number),
        processInstanceUUID: fixtureUUID(200 + number)
    ) else {
        throw FakeRuntimeFactoryError.requestedFailure
    }
    return BackendCanonicalSession(
        transport: ReconcilerInertTransport(),
        expectation: BackendCanonicalSessionExpectation(session: "reconciler-\(number)"),
        registrationIdentity: registration
    )
}

private func balancedLayout(
    _ slots: ArraySlice<BackendOnlyProjectionSlotID>
) -> BackendOnlyProjectionLayout {
    precondition(!slots.isEmpty)
    if slots.count == 1 {
        return .pane(slots[slots.startIndex])
    }
    let midpoint = slots.index(slots.startIndex, offsetBy: slots.count / 2)
    return .split(
        direction: .right,
        ratio: 0.5,
        first: balancedLayout(slots[..<midpoint]),
        second: balancedLayout(slots[midpoint...])
    )
}

private func balancedLayout(
    _ slots: [BackendOnlyProjectionSlotID]
) -> BackendOnlyProjectionLayout {
    balancedLayout(slots[...])
}

private func fixtureUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", value))!
}

private extension BackendOnlyProjectionPaneContent {
    var kindForFixture: String {
        switch self {
        case .terminal:
            "terminal"
        case .browserPlaceholder:
            "browser"
        case .unsupportedPlaceholder(_, _, let kind):
            kind
        }
    }
}
