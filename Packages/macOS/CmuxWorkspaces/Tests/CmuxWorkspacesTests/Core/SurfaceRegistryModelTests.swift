import Combine
import Foundation
import Testing
@testable import CmuxWorkspaces

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
        #expect(model.panelDirectories.isEmpty)
        #expect(model.panelTitles.isEmpty)
        #expect(model.panelCustomTitles.isEmpty)
        #expect(model.surfaceListeningPorts.isEmpty)
    }

    @Test("directory/title/port maps round-trip and support filter-style pruning")
    func directoryTitlePortRoundtrip() {
        let model = SurfaceRegistryModel<StubRequest>()
        let kept = UUID()
        let dropped = UUID()
        model.panelDirectories = [kept: "/a", dropped: "/b"]
        model.panelTitles = [kept: "A", dropped: "B"]
        model.panelCustomTitles = [kept: "Custom"]
        model.surfaceListeningPorts = [kept: [3000, 8080], dropped: [9000]]

        let valid: Set<UUID> = [kept]
        model.panelDirectories = model.panelDirectories.filter { valid.contains($0.key) }
        model.panelTitles = model.panelTitles.filter { valid.contains($0.key) }
        model.surfaceListeningPorts = model.surfaceListeningPorts.filter { valid.contains($0.key) }

        #expect(model.panelDirectories == [kept: "/a"])
        #expect(model.panelTitles == [kept: "A"])
        #expect(model.panelCustomTitles == [kept: "Custom"])
        #expect(model.surfaceListeningPorts == [kept: [3000, 8080]])
    }

    @Test("directory/title publishers replay current value then emit every assignment")
    func publisherObserverParity() {
        let model = SurfaceRegistryModel<StubRequest>()
        let panel = UUID()
        model.panelDirectories = [panel: "/seed"]

        var directorySnapshots: [[UUID: String]] = []
        var titleSnapshots: [[UUID: String]] = []
        var customSnapshots: [[UUID: String]] = []
        var cancellables = Set<AnyCancellable>()

        // Replay-on-subscribe: each subject emits its current value immediately,
        // matching the @Published projection the legacy subscribers relied on.
        model.panelDirectoriesPublisher.sink { directorySnapshots.append($0) }.store(in: &cancellables)
        model.panelTitlesPublisher.sink { titleSnapshots.append($0) }.store(in: &cancellables)
        model.panelCustomTitlesPublisher.sink { customSnapshots.append($0) }.store(in: &cancellables)

        #expect(directorySnapshots == [[panel: "/seed"]])
        #expect(titleSnapshots == [[:]])
        #expect(customSnapshots == [[:]])

        model.panelDirectories[panel] = "/changed"
        model.panelTitles[panel] = "Title"
        model.panelCustomTitles[panel] = "Custom"
        // Send-on-equal-assignment parity: re-assigning the same value still emits,
        // exactly as @Published did.
        model.panelTitles[panel] = "Title"

        #expect(directorySnapshots == [[panel: "/seed"], [panel: "/changed"]])
        #expect(titleSnapshots == [[:], [panel: "Title"], [panel: "Title"]])
        #expect(customSnapshots == [[:], [panel: "Custom"]])
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
