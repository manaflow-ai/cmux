import Foundation
import Testing
@testable import CmuxWorkspaceCore

@MainActor
@Suite("SurfaceRegistryModel")
struct SurfaceRegistryModelTests {
    private struct StubRequest: Equatable {
        let token: Int
    }

    @Test("starts empty, matching the legacy stored-property defaults")
    func initialState() {
        let model = SurfaceRegistryModel<StubRequest>()
        #expect(model.pendingTabSelection == nil)
        #expect(model.isApplyingTabSelection == false)
        #expect(model.pendingNonFocusSplitFocusReassert == nil)
        #expect(model.nonFocusSplitFocusReassertGeneration == 0)
        #expect(model.surfaceTTYNames.isEmpty)
        #expect(model.panelShellActivityStates.isEmpty)
    }

    @Test("stores and drains a pending tab-selection request")
    func pendingTabSelectionRoundtrip() {
        let model = SurfaceRegistryModel<StubRequest>()
        model.pendingTabSelection = StubRequest(token: 7)
        model.isApplyingTabSelection = true
        #expect(model.pendingTabSelection == StubRequest(token: 7))
        model.pendingTabSelection = nil
        model.isApplyingTabSelection = false
        #expect(model.pendingTabSelection == nil)
        #expect(model.isApplyingTabSelection == false)
    }

    @Test("stores a focus re-assert request alongside its generation")
    func focusReassertRoundtrip() {
        let model = SurfaceRegistryModel<StubRequest>()
        let preferred = UUID()
        let split = UUID()
        model.nonFocusSplitFocusReassertGeneration &+= 1
        let request = PendingNonFocusSplitFocusReassert(
            generation: model.nonFocusSplitFocusReassertGeneration,
            preferredPanelId: preferred,
            splitPanelId: split
        )
        model.pendingNonFocusSplitFocusReassert = request
        #expect(model.pendingNonFocusSplitFocusReassert == request)
        #expect(model.pendingNonFocusSplitFocusReassert?.generation == 1)
        model.pendingNonFocusSplitFocusReassert = nil
        #expect(model.pendingNonFocusSplitFocusReassert == nil)
    }

    @Test("registry maps support the workspace's filter-style pruning")
    func registryMapPruning() {
        let model = SurfaceRegistryModel<StubRequest>()
        let kept = UUID()
        let dropped = UUID()
        model.surfaceTTYNames = [kept: "/dev/ttys001", dropped: "/dev/ttys002"]
        model.panelShellActivityStates = [kept: .commandRunning, dropped: .promptIdle]

        let valid: Set<UUID> = [kept]
        model.surfaceTTYNames = model.surfaceTTYNames.filter { valid.contains($0.key) }
        model.panelShellActivityStates = model.panelShellActivityStates.filter { valid.contains($0.key) }

        #expect(model.surfaceTTYNames == [kept: "/dev/ttys001"])
        #expect(model.panelShellActivityStates == [kept: .commandRunning])
    }
}
