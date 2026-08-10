import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite(.serialized)
struct TerminalSurfaceExternalRuntimeTests {
    @Test func externalSurfaceRebasesFontLineageWithoutEmbeddedRuntimeOwnership() {
        let fontConfiguration = FakeTerminalFontConfigurationSource(
            snapshot: TerminalFontConfigurationSnapshot(
                generation: 1,
                runtimePoints: 12
            )
        )
        var template = CmuxSurfaceConfigTemplate()
        template.fontSizeLineage = TerminalFontSizeLineage(
            basePoints: 12,
            isExplicitOverride: false
        )
        let fixture = makeFixture(
            configTemplate: template,
            fontConfigurationSnapshot: { fontConfiguration.snapshot }
        )
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }

        fontConfiguration.snapshot = TerminalFontConfigurationSnapshot(
            generation: 2,
            runtimePoints: 18
        )

        #expect(
            fixture.surface.fontSizeLineageSnapshot(magnificationPercent: 100)
                == TerminalFontSizeLineage(
                    basePoints: 18,
                    isExplicitOverride: false
                )
        )
        #expect(fixture.surface.fontSizeLineageConfigurationGeneration == 2)
        #expect(fixture.surface.embeddedRuntime == nil)
    }

    @Test func externalSurfaceNeverCreatesEmbeddedGhosttyRuntimeOrBootstrapWindow() {
        let fixture = makeFixture(initialInput: "echo should-run-in-backend")
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }

        #expect(fixture.surface.isExternallyManaged)
        #expect(fixture.surface.embeddedRuntime == nil)
        #expect(fixture.surface.surfaceView.renderOwnership == .externalCompositor)
        #expect(fixture.surface.compositorHostView === fixture.surface.surfaceView)
        #expect(fixture.surface.hasLiveSurface)
        #expect(fixture.surface.surface == nil)
        #expect(fixture.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(!fixture.surface.debugHasHeadlessStartupWindowForTesting())
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

    @Test func externalSurfaceKeepsCanonicalTerminalLifecycleIdentity() {
        let surfaceID = UUID()
        let first = makeFixture(
            surfaceID: surfaceID,
            terminalLifecycleID: surfaceID
        )
        let second = makeFixture(
            surfaceID: surfaceID,
            terminalLifecycleID: surfaceID
        )
        defer {
            first.surface.detachExternalPresentationPreservingCanonicalTerminal()
            second.surface.detachExternalPresentationPreservingCanonicalTerminal()
        }

        #expect(first.surface.terminalLifecycleId == surfaceID)
        #expect(second.surface.terminalLifecycleId == surfaceID)
    }

    @Test func rapidExternalCopyModeTogglesUseAcceptedLocalState() {
        let fixture = makeFixture()
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }

        #expect(fixture.surface.toggleKeyboardCopyMode())
        #expect(fixture.surface.toggleKeyboardCopyMode())

        #expect(fixture.runtime.mutations == [
            .copyMode(operation: .enter, adjustment: nil, count: 1),
            .copyMode(operation: .exit, adjustment: nil, count: 1),
        ])
        #expect(!fixture.surface.keyboardCopyModeActive)
    }

    @Test func externalSurfaceRejectsEmbeddedManualIOWithoutTrap() {
        let fixture = makeFixture()
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }

        fixture.surface.setManualIONoReflow(true)
        fixture.surface.processRemoteOutput(Data("remote output".utf8))

        #expect(fixture.runtime.mutations.isEmpty)
        #expect(fixture.surface.hasLiveSurface)
    }

    @Test func canonicalProjectionOwnsCloseCommitAndPresentationRetirement() {
        let explicitlyClosed = makeFixture()
        let closeLease = explicitlyClosed.runtime.leases[0]

        explicitlyClosed.surface.teardownSurface()
        explicitlyClosed.surface.teardownSurface()

        #expect(explicitlyClosed.runtime.mutations.isEmpty)
        #expect(closeLease.detachCount == 0)
        #expect(explicitlyClosed.surface.hasLiveSurface)

        #expect(explicitlyClosed.surface.requestCanonicalClose().accepted)
        #expect(explicitlyClosed.runtime.mutations == [.closeCanonicalTerminal])
        #expect(closeLease.detachCount == 0)
        #expect(explicitlyClosed.surface.hasLiveSurface)

        explicitlyClosed.surface.detachExternalPresentationPreservingCanonicalTerminal()
        explicitlyClosed.surface.teardownSurface()

        #expect(closeLease.detachCount == 1)
        #expect(!explicitlyClosed.surface.hasLiveSurface)

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

    @Test func rejectedCanonicalCloseKeepsPresentationAttachedAndRemainsRetryable() {
        let fixture = makeFixture()
        let lease = fixture.runtime.leases[0]
        fixture.runtime.rejectNext(.queueFull)

        #expect(!fixture.surface.requestCanonicalClose().accepted)

        #expect(fixture.runtime.mutations.isEmpty)
        #expect(lease.detachCount == 0)

        #expect(fixture.surface.requestCanonicalClose().accepted)

        #expect(fixture.runtime.mutations == [.closeCanonicalTerminal])
        #expect(lease.detachCount == 0)
        #expect(fixture.surface.hasLiveSurface)

        fixture.surface.detachExternalPresentationPreservingCanonicalTerminal()
        fixture.surface.teardownSurface()
        #expect(lease.detachCount == 1)
    }

    @Test func rejectedFocusRemainsRetryable() {
        let fixture = makeFixture()
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }
        fixture.runtime.rejectNext(.queueFull)

        fixture.surface.setFocus(true)

        #expect(!fixture.surface.debugDesiredFocusState())
        #expect(fixture.runtime.mutations.isEmpty)

        fixture.surface.setFocus(true)

        #expect(fixture.surface.debugDesiredFocusState())
        #expect(fixture.runtime.mutations == [.focus(true)])
    }

    @Test func reparentInstallsOnlyFromCanonicalProjection() {
        let fixture = makeFixture()
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }
        let originalWorkspaceID = fixture.surface.tabId
        let destinationWorkspaceID = UUID()
        fixture.runtime.rejectNext(.queueFull)

        fixture.surface.updateWorkspaceId(destinationWorkspaceID)

        #expect(fixture.runtime.mutations.isEmpty)
        #expect(fixture.surface.tabId == originalWorkspaceID)

        fixture.surface.updateWorkspaceId(destinationWorkspaceID)

        #expect(fixture.runtime.mutations == [.reparent(workspaceID: destinationWorkspaceID)])
        #expect(fixture.surface.tabId == originalWorkspaceID)

        fixture.surface.installCanonicalWorkspaceId(destinationWorkspaceID)

        #expect(fixture.surface.tabId == destinationWorkspaceID)
        #expect(fixture.surface.surfaceView.tabId == destinationWorkspaceID)
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

    @Test func accessibilityDemandForwardsBothEdgesToExternalRuntime() {
        let fixture = makeFixture()
        defer { fixture.surface.detachExternalPresentationPreservingCanonicalTerminal() }

        fixture.surface.enableExternalAccessibility()
        fixture.surface.disableExternalAccessibility()

        #expect(fixture.runtime.accessibilityEnableCount == 1)
        #expect(fixture.runtime.accessibilityDisableCount == 1)
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
        surfaceID: UUID = UUID(),
        terminalLifecycleID: UUID? = nil,
        initialInput: String? = nil,
        runtime: FakeExternalTerminalRuntime? = nil,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        fontConfigurationSnapshot: @escaping
            @MainActor @Sendable () -> TerminalFontConfigurationSnapshot? = { nil }
    ) -> (
        surface: TerminalSurface,
        runtime: FakeExternalTerminalRuntime
    ) {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        nativeView.renderOwnership = .externalCompositor
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let resolvedRuntime = runtime ?? FakeExternalTerminalRuntime(snapshot: Self.liveSnapshot)
        let surface = TerminalSurface(
            id: surfaceID,
            terminalLifecycleId: terminalLifecycleID ?? surfaceID,
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: configTemplate,
            initialInput: initialInput,
            externalRuntime: resolvedRuntime,
            presentationDependencies: TerminalSurfacePresentationDependencies(
                registry: FakeSurfaceRegistry(),
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: paneHost
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                hibernationRecorder: FakeHibernationRecorder(),
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY",
                fontConfigurationSnapshot: fontConfigurationSnapshot
            )
        )
        return (surface, resolvedRuntime)
    }
}

@MainActor
private final class FakeTerminalFontConfigurationSource {
    var snapshot: TerminalFontConfigurationSnapshot

    init(snapshot: TerminalFontConfigurationSnapshot) {
        self.snapshot = snapshot
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
    private(set) var accessibilityEnableCount = 0
    private(set) var accessibilityDisableCount = 0
    private var nextSequence: UInt64 = 1
    private var nextRejection: TerminalExternalIngressRejection?

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
        if let nextRejection {
            self.nextRejection = nil
            return .rejected(nextRejection)
        }
        let sequence = nextSequence
        nextSequence += 1
        mutations.append(mutation)
        acceptedSequences.append(sequence)
        return .accepted(sequence: sequence)
    }

    func rejectNext(_ rejection: TerminalExternalIngressRejection) {
        nextRejection = rejection
    }

    func readScreenText(_ request: TerminalExternalScreenTextRequest) async -> String? {
        screenRequests.append(request)
        return request == .visible ? snapshot.visibleText : "vt-tail"
    }

    func readSelection() async -> TerminalExternalSelection? {
        snapshot.selection
    }

    func enableAccessibility() {
        accessibilityEnableCount += 1
    }

    func disableAccessibility() {
        accessibilityDisableCount += 1
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
