import AppKit
@testable import CmuxNextAppCore
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The next Cmd-N's workspace view slot (STATUS 15250): it builds in three background tasks (reserve, build, mount),
/// so no one task holds the main thread for the whole view; a key's show takes it and builds nothing; a drop or a
/// stale reservation lets it go.
@MainActor struct WorkspaceSpareSlotTests {
    private final class Content {
        let workspace: WorkspaceModel
        var mounted = false
        var tornDown = false
        init(_ workspace: WorkspaceModel) { self.workspace = workspace }
    }

    /// A slot whose steps run only when the test runs them, one per call, as the background queue does one per task.
    private final class Harness {
        var steps: [@MainActor () -> Void] = []
        var wanted = true
        var reservation: WorkspaceModel? = WorkspaceModel(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: .generate(), name: "", screens: []))
        var built: [Content] = []
        var log: [String] = []
        private(set) lazy var slot = WorkspaceSpareSlot<Content>(
            enqueue: { [unowned self] in steps.append($0) }, wanted: { [unowned self] in wanted },
            reserve: { [unowned self] in log.append("reserve"); return reservation },
            build: { [unowned self] in log.append("build"); let content = Content($0); built.append(content); return content },
            mount: { [unowned self] in log.append("mount"); $0.mounted = true },
            teardown: { $0.tornDown = true }, workspace: { $0.workspace }, isReserved: { [unowned self] in $0 === reservation })

        func runStep() { steps.removeFirst()() }
    }

    @Test func buildsInThreeSeparateTasksAndTheKeyTakesIt() throws {
        let harness = Harness()
        harness.slot.start()
        for expected in [["reserve"], ["reserve", "build"], ["reserve", "build", "mount"]] {
            #expect(harness.slot.ready == nil)
            #expect(harness.steps.count == 1, "one step per background task")
            harness.runStep()
            #expect(harness.log == expected)
        }
        let ready = try #require(harness.slot.ready)
        #expect(ready.mounted)
        #expect(harness.slot.take { $0.workspace !== ready.workspace } == nil, "another workspace's show takes nothing")
        #expect(harness.slot.take { $0.workspace === ready.workspace } === ready)
        #expect(harness.slot.ready == nil && !ready.tornDown)
    }

    @Test func aDropDuringTheFillTearsTheBuiltViewDown() {
        let harness = Harness()
        harness.slot.start()
        harness.runStep()
        harness.runStep()
        harness.slot.drop()
        harness.runStep()
        #expect(harness.slot.ready == nil)
        #expect(harness.built.first?.tornDown == true)
        #expect(harness.built.first?.mounted == false, "a dropped fill mounts nothing")
    }

    @Test func aStaleViewGoesAtTheNextFillAndANewOneIsBuilt() throws {
        let harness = Harness()
        harness.slot.start()
        (0..<3).forEach { _ in harness.runStep() }
        let first = try #require(harness.slot.ready)
        harness.reservation = WorkspaceModel(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: .generate(), name: "", screens: []))
        harness.slot.start()
        #expect(first.tornDown)
        (0..<3).forEach { _ in harness.runStep() }
        #expect(harness.slot.ready?.workspace === harness.reservation)
    }

    @Test func nothingIsMadeWhileUnwantedOrWithoutAReservation() {
        let harness = Harness()
        harness.wanted = false
        harness.slot.start()
        #expect(harness.steps.isEmpty)
        harness.wanted = true
        harness.reservation = nil
        harness.slot.start()
        harness.runStep()
        #expect(harness.steps.isEmpty && harness.log == ["reserve"])
        harness.reservation = WorkspaceModel(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 3), key: .generate(), name: "", screens: []))
        harness.slot.start()
        harness.wanted = false
        harness.runStep()
        #expect(harness.steps.isEmpty, "a fill stops when its window is no longer the key main window")
        #expect(harness.slot.ready == nil)
    }

    @Test func aFillDropsTheOtherWindowsViews() throws {
        let (key, other) = (Harness(), Harness())
        other.slot.start()
        (0..<3).forEach { _ in other.runStep() }
        let otherView = try #require(other.slot.ready)
        key.slot.fill { [other.slot, key.slot] }
        // `fill` runs after the frame commits: let the main run loop turn once.
        for _ in 0..<50 where other.slot.ready != nil { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        #expect(other.slot.ready == nil && otherView.tornDown)
        #expect(key.steps.count == 1, "the key window's own fill started")
    }

    /// A key took the reservation before the build step: no view is built on the workspace the window now shows.
    @Test func aKeyBeforeTheBuildLeavesNothingToBuild() {
        let harness = Harness()
        harness.slot.start()
        harness.runStep()
        harness.reservation = nil // the key's create intent took it
        harness.runStep()
        #expect(harness.built.isEmpty, "a view was built on the workspace the key shows")
        #expect(harness.steps.isEmpty && harness.slot.ready == nil)
    }

    /// A key between the build and the mount takes the built view and mounts it in its turn; the mount step does nothing.
    @Test func aKeyBetweenBuildAndMountTakesTheBuiltView() throws {
        let harness = Harness()
        harness.slot.start()
        harness.runStep()
        harness.runStep()
        let built = try #require(harness.built.first)
        let model = harness.reservation
        #expect(harness.slot.take { $0.workspace === model } === built)
        #expect(built.mounted && !built.tornDown)
        harness.reservation = nil
        harness.runStep()
        #expect(!built.tornDown && harness.slot.ready == nil && harness.built.count == 1)
    }
}
