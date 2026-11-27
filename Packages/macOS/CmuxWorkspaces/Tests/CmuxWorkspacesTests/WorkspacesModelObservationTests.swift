import Foundation
import Observation
import os
import Testing
@testable import CmuxWorkspaces

/// The observation contract sidebar, right sidebar and command palette views
/// rely on when their bodies read `WorkspacesModel` through `TabManager`:
/// each stored member invalidates only its own tracked reads, before the host
/// hook runs, and equal assignments of `Equatable` members invalidate nothing.
@MainActor
@Suite struct WorkspacesModelObservationTests {
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])

    private func makeModel() -> (WorkspacesModel<ObservedStubTab>, EventLogHost) {
        let model = WorkspacesModel<ObservedStubTab>()
        let host = EventLogHost(log: log)
        model.attach(host: host)
        return (model, host)
    }

    private func track(_ name: String, _ read: () -> Void) {
        let log = log
        withObservationTracking(read, onChange: {
            log.withLock { $0.append("onChange(\(name))") }
        })
    }

    private func drainLog() -> [String] {
        log.withLock { events in
            defer { events.removeAll() }
            return events
        }
    }

    @Test(arguments: WorkspacesModelObservationMember.allCases)
    func changingAMemberInvalidatesItsTrackedReadBeforeTheHostHookRuns(_ member: WorkspacesModelObservationMember) {
        let (model, host) = makeModel()
        track(member.rawValue) { member.read(model) }

        member.change(model)

        #expect(drainLog() == ["onChange(\(member.rawValue))"] + member.hookEvents)
        withExtendedLifetime(host) {}
    }

    @Test(arguments: WorkspacesModelObservationMember.allCases)
    func changingAMemberLeavesTrackedReadsOfOtherMembersValid(_ member: WorkspacesModelObservationMember) {
        let (model, host) = makeModel()
        let others = WorkspacesModelObservationMember.allCases.filter { $0 != member }
        track("others") {
            for other in others { other.read(model) }
        }

        member.change(model)

        #expect(drainLog() == member.hookEvents)
        withExtendedLifetime(host) {}
    }

    @Test
    func inPlaceTabsMutationInvalidatesTrackedTabsRead() {
        let (model, host) = makeModel()
        track("tabs") { _ = model.tabs }

        model.tabs.append(ObservedStubTab())

        #expect(drainLog() == ["onChange(tabs)", "tabs.willSet"])
        #expect(model.tabs.count == 1)
        withExtendedLifetime(host) {}
    }

    @Test
    func equalGroupsAndSelectionAssignmentsRunHostHooksWithoutInvalidating() {
        let (model, host) = makeModel()
        let group = WorkspacesModelObservationMember.group(named: "group")
        let selection = UUID()
        model.workspaceGroups = [group]
        model.selectedTabId = selection
        _ = drainLog()
        track("groups+selection") {
            _ = model.workspaceGroups
            _ = model.selectedTabId
        }

        model.workspaceGroups = [group]
        model.selectedTabId = selection

        // Hooks keep legacy @Published parity; the tracked views don't rebuild.
        #expect(drainLog() == ["groups.willSet", "selection.willSet", "selection.didSet"])
        withExtendedLifetime(host) {}
    }

    @Test
    func tabLookupIsTrackedAsATabsRead() {
        let (model, host) = makeModel()
        let tab = ObservedStubTab()
        model.tabs = [tab]
        _ = drainLog()
        track("tab(id:)") { _ = model.tab(id: tab.id) }

        // selectedWorkspace reads through tab(id:): selection and group
        // changes don't invalidate it, a tabs change does.
        model.selectedTabId = tab.id
        model.workspaceGroups = [WorkspacesModelObservationMember.group(named: "group")]
        model.tabs.removeAll()

        #expect(drainLog() == [
            "selection.willSet", "selection.didSet", "groups.willSet",
            "onChange(tab(id:))", "tabs.willSet",
        ])
        #expect(model.tab(id: tab.id) == nil)
        withExtendedLifetime(host) {}
    }

    @Test
    func tabIndexMatchesTheIncomingTabsWhenTheHostHookRuns() {
        let model = WorkspacesModel<ObservedStubTab>()
        let host = IndexProbeHost()
        host.model = model
        model.attach(host: host)
        let first = ObservedStubTab()
        let second = ObservedStubTab()

        model.tabs = [first]
        model.tabs.append(second)
        model.tabs.removeFirst()

        #expect(host.indexMatchedIncomingTabs == [true, true, true])
        #expect(model.tabsById.count == 1)
        #expect(model.tab(id: second.id) === second)
        #expect(model.tab(id: first.id) == nil)
    }

    @Test
    func reassigningTheSameTabsInvalidatesTrackedTabsRead() {
        let (model, host) = makeModel()
        model.tabs = [ObservedStubTab()]
        _ = drainLog()
        track("tabs") { _ = model.tabs }

        // Workspace has no equality, so every tabs assignment is a change.
        model.tabs = model.tabs

        #expect(drainLog() == ["onChange(tabs)", "tabs.willSet"])
        withExtendedLifetime(host) {}
    }
}
