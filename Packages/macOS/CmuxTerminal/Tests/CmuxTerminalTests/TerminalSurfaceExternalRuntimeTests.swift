import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite(.serialized)
struct TerminalSurfaceExternalRuntimeTests {
    @Test func externalSurfaceNeverCreatesEmbeddedGhosttyRuntimeOrBootstrapWindow() {
        let fixture = makeFixture(initialInput: "echo should-run-in-backend")
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }

        #expect(fixture.surface.isExternallyManaged)
        #expect(fixture.surface.surfaceView.renderOwnership == .externalCompositor)
        #expect(fixture.surface.compositorHostView === fixture.surface.surfaceView)
        #expect(fixture.surface.hasLiveSurface)
        #expect(fixture.surface.surface == nil)
        #expect(fixture.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(!fixture.surface.debugHasHeadlessStartupWindowForTesting())
        #expect(fixture.engine.runtimeAppAccessCount == 0)
        #expect(fixture.engine.runtimeConfigAccessCount == 0)
        #expect(fixture.runtime.presentations == [
            TerminalExternalPresentation(
                surfaceID: fixture.surface.id,
                workspaceID: fixture.surface.tabId
            )
        ])
    }

    @Test func inputFocusVisibilityResizeAndReparentUseOneOrderedIngress() {
        let fixture = makeFixture()
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }

        #expect(fixture.surface.sendText("paste"))
        #expect(fixture.surface.sendNamedKey("enter") == .queued)
        #expect(fixture.surface.sendExternalKeyEvent(TerminalExternalKeyEvent(
            key: 42,
            modifiers: [.control],
            text: "a",
            unshiftedCodepoint: 97
        )).accepted)
        #expect(fixture.surface.setExternalPreedit("かな").accepted)
        let mouse = TerminalExternalMouseEvent(
            action: .press,
            button: .left,
            modifiers: [.shift],
            xPixels: 12,
            yPixels: 24,
            anyButtonPressed: true
        )
        #expect(fixture.surface.sendExternalMouseEvent(mouse).accepted)
        fixture.surface.setFocus(true)
        fixture.surface.setOcclusion(false)
        #expect(fixture.surface.updateSize(
            width: 400,
            height: 200,
            xScale: 2,
            yScale: 2,
            layerScale: 2
        ))
        let newWorkspaceID = UUID()
        fixture.surface.updateWorkspaceId(newWorkspaceID)

        #expect(fixture.runtime.acceptedSequences == Array(1...9))
        #expect(fixture.runtime.mutations.count == 9)
        #expect(fixture.runtime.mutations[0] == .input(.text(
            TerminalExternalTextInput(text: "paste", kind: .paste)
        )))
        #expect(fixture.runtime.mutations[1] == .input(.namedKey("enter")))
        #expect(fixture.runtime.mutations[2] == .input(.key(TerminalExternalKeyEvent(
            key: 42,
            modifiers: [.control],
            text: "a",
            unshiftedCodepoint: 97
        ))))
        #expect(fixture.runtime.mutations[3] == .preedit(.collapsedAtEnd("かな")))
        #expect(fixture.runtime.mutations[4] == .mouse(mouse))
        #expect(fixture.runtime.mutations[5] == .focus(true))
        #expect(fixture.runtime.mutations[6] == .visibility(false))
        guard case .resize(let viewport) = fixture.runtime.mutations[7] else {
            Issue.record("eighth ordered mutation must be resize")
            return
        }
        #expect(viewport.widthPixels == 800)
        #expect(viewport.heightPixels == 400)
        #expect(viewport.proposedColumns == 99)
        #expect(viewport.proposedRows == 19)
        #expect(fixture.runtime.mutations[8] == .reparent(workspaceID: newWorkspaceID))
        #expect(fixture.surface.surface == nil)
    }

    @Test func explicitTeardownClosesOnceThenDetachesWhileDeinitOnlyDetaches() {
        let explicitlyClosed = makeFixture()
        let closeLease = explicitlyClosed.runtime.leases[0]
        explicitlyClosed.surface.teardownSurface()
        explicitlyClosed.surface.teardownSurface()

        #expect(explicitlyClosed.runtime.mutations.filter { $0 == .closeCanonicalTerminal }.count == 1)
        #expect(closeLease.detachCount == 1)

        let detachedRuntime = FakeExternalTerminalRuntime(snapshot: Self.liveSnapshot)
        var detachedSurface: TerminalSurface? = makeFixture(runtime: detachedRuntime).surface
        let detachLease = detachedRuntime.leases[0]
        detachedSurface?.detachExternalPresentationPreservingCanonicalTerminal()
        detachedSurface?.teardownSurface()
        detachedSurface = nil

        #expect(detachedRuntime.mutations.filter {
            $0 == TerminalExternalRuntimeMutation.closeCanonicalTerminal
        }.isEmpty)
        #expect(detachLease.detachCount == 1)

        let deinitRuntime = FakeExternalTerminalRuntime(snapshot: Self.liveSnapshot)
        var deinitializedSurface: TerminalSurface? = makeFixture(runtime: deinitRuntime).surface
        let deinitLease = deinitRuntime.leases[0]
        #expect(deinitializedSurface != nil)
        deinitializedSurface = nil

        #expect(deinitRuntime.mutations.filter {
            $0 == TerminalExternalRuntimeMutation.closeCanonicalTerminal
        }.isEmpty)
        #expect(deinitLease.detachCount == 1)
    }

    @Test func cachedScreenProcessAndCellStateRouteToExternalRuntime() async {
        let fixture = makeFixture()
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }

        #expect(fixture.surface.visibleText() == "visible")
        #expect(fixture.surface.foregroundProcessID() == 4321)
        #expect(fixture.surface.controllingTTYName() == "/dev/ttys999")
        #expect(fixture.surface.cellSizePoints() == CGSize(width: 4, height: 10))
        #expect(await fixture.surface.boundedScreenTailVT(maxRows: 20, maxBytes: 4096) == "vt-tail")
        #expect(fixture.runtime.screenRequests == [.vtTail(maxRows: 20, maxBytes: 4096)])
    }

    @Test func canonicalWorkspaceInstallDoesNotEchoBackendReparent() {
        let fixture = makeFixture()
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }
        let workspaceID = UUID()

        fixture.surface.installCanonicalWorkspaceId(workspaceID)

        #expect(fixture.surface.tabId == workspaceID)
        #expect(fixture.surface.surfaceView.tabId == workspaceID)
        #expect(fixture.runtime.mutations.isEmpty)
    }

    private static let liveSnapshot = TerminalExternalRuntimeSnapshot(
        lifecycle: .live,
        visibleText: "visible",
        cellMetrics: TerminalExternalCellMetrics(
            columns: 80,
            rows: 24,
            cellWidthPixels: 8,
            cellHeightPixels: 20,
            surfaceWidthPixels: 648,
            surfaceHeightPixels: 488,
            backingScale: 2
        ),
        processMetadata: TerminalExternalProcessMetadata(
            foregroundProcessID: 4321,
            controllingTTYName: "/dev/ttys999"
        )
    )

    private func makeFixture(
        initialInput: String? = nil,
        runtime: FakeExternalTerminalRuntime? = nil
    ) -> (
        surface: TerminalSurface,
        runtime: FakeExternalTerminalRuntime,
        engine: FakeTerminalEngine
    ) {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        nativeView.renderOwnership = .externalCompositor
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let engine = FakeTerminalEngine()
        let resolvedRuntime = runtime ?? FakeExternalTerminalRuntime(snapshot: Self.liveSnapshot)
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialInput: initialInput,
            externalRuntime: resolvedRuntime,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: engine,
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: paneHost
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    claudeCommandShimTemporaryDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-external-runtime-tests",
                        isDirectory: true
                    ),
                    installClaudeCommandShim: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
        return (surface, resolvedRuntime, engine)
    }
}

@MainActor
private final class FakeExternalTerminalRuntime: TerminalExternalRuntime {
    var snapshot: TerminalExternalRuntimeSnapshot
    private(set) var presentations: [TerminalExternalPresentation] = []
    private(set) var leases: [RecordingExternalPresentationLease] = []
    private(set) var mutations: [TerminalExternalRuntimeMutation] = []
    private(set) var acceptedSequences: [UInt64] = []
    private(set) var screenRequests: [TerminalExternalScreenTextRequest] = []
    private var nextSequence: UInt64 = 1

    init(snapshot: TerminalExternalRuntimeSnapshot) {
        self.snapshot = snapshot
    }

    func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease {
        let lease = RecordingExternalPresentationLease()
        presentations.append(presentation)
        leases.append(lease)
        return lease
    }

    func enqueue(_ mutation: TerminalExternalRuntimeMutation) -> TerminalExternalIngressResult {
        let sequence = nextSequence
        nextSequence += 1
        mutations.append(mutation)
        acceptedSequences.append(sequence)
        return .accepted(sequence: sequence)
    }

    func readScreenText(_ request: TerminalExternalScreenTextRequest) async -> String? {
        screenRequests.append(request)
        return request == .visible ? snapshot.visibleText : "vt-tail"
    }

    func readSelection() async -> TerminalExternalSelection? {
        snapshot.selection
    }
}

private final class RecordingExternalPresentationLease: TerminalExternalPresentationLease, @unchecked Sendable {
    private let lock = NSLock()
    private var detached = false
    private var count = 0

    var detachCount: Int {
        lock.withLock { count }
    }

    nonisolated func detach() {
        lock.withLock {
            guard !detached else { return }
            detached = true
            count += 1
        }
    }
}
