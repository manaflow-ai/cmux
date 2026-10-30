import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// P-AUSTIN B7 display: a Cloud workspace a window keeps while no machine lists it (signed out of
/// cmux Cloud, Cloud turned off, its machine paused or not loaded yet) shows as not connected in its
/// window and in its sidebar, never as a blank pane, and a window that holds only such workspaces
/// shows that state (review of #28358, finding 6: before #28358 that window closed; with it, it
/// stayed open with its old content or an empty pane).
@MainActor @Suite(.serialized)
struct CloudWorkspaceAbsentDisplayTests {
    static let workspace = "ws-cloud-absent"

    // MARK: The state

    @Test func theStateSaysWhatBringsTheWorkspaceBack() {
        func absence(cloudOn: Bool = true, signedIn: Bool = true, restoring: Bool = false, listed: Bool = true, live: Bool = true) -> CloudWorkspaceAbsence {
            CloudWorkspaceAbsence(cloudOn: cloudOn, signedIn: signedIn, restoring: restoring, machineListed: listed, machineLive: live)
        }
        #expect(absence(signedIn: false, listed: false) == .signedOut)
        #expect(absence(signedIn: false, listed: false).action == .signIn, "signed out: Sign In brings it back")
        #expect(absence(cloudOn: false, signedIn: false) == .cloudOff, "Cloud off wins: signing in would not connect it")
        #expect(absence(cloudOn: false).action == nil)
        #expect(absence(live: false) == .paused)
        #expect(absence(live: false).action == .resume, "paused: Resume Machine brings it back")
        #expect(absence(listed: false) == .connecting, "signed in, the list not loaded: it connects by itself")
        #expect(absence(signedIn: false, restoring: true, listed: false) == .connecting, "the saved sign-in is restoring")
        #expect(absence().action == nil)
    }

    // MARK: The sidebar

    @Test func aKeptWorkspaceRowGoesUnderItsMachineAndAMachineWithNoSectionGetsOne() {
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                   nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-l"), title: "local"))])
        let paused = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("vm-p"), name: "Paused VM", kind: .cloud, status: .paused)),
                                    nodes: [])
        let onPaused = SidebarWorkspace(id: WorkspaceID("ws-p"), machineID: MachineID("vm-p"), title: "on paused")
        let signedOut = SidebarWorkspace(id: WorkspaceID("ws-o"), machineID: MachineID("vm-o"), title: "signed out")
        let listed = SidebarWorkspace(id: WorkspaceID("ws-l"), title: "again")
        let header = SidebarMachine(id: MachineID("vm-o"), name: "Old VM", kind: .cloud, status: .offline)
        let sections = SidebarSection.adding(absent: [onPaused, signedOut, listed], header: { _ in header }, to: [local, paused])
        #expect(sections.map(\.id) == [.machine(.local), .machine(MachineID("vm-p")), .machine(MachineID("vm-o"))])
        #expect(sections[0].workspaces.map(\.title) == ["local"], "a row a section lists already is not added again")
        #expect(sections[1].workspaces.map(\.id) == [WorkspaceID("ws-p")])
        #expect(sections[2].machine == header)
        #expect(sections[2].workspaces.map(\.id) == [WorkspaceID("ws-o")])
    }

    // MARK: The window

    /// Signed out, a window that holds only a Cloud workspace shows it as not connected with Sign In,
    /// is on screen (not kept off screen for content that cannot come), breaks no window invariant,
    /// and its sidebar lists the workspace under its machine, saying why.
    @Test func aSignedOutWindowWithOnlyACloudWorkspaceShowsItAsSignedOut() async throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let controller = fixture.controller
        #expect(controller.shownCloudAbsence?.workspaceID == Self.workspace, "the window shows no state for its Cloud workspace")
        #expect(controller.shownCloudAbsence?.absence == .signedOut)
        #expect(fixture.services.windows.awaitingContent[controller.state.id] == nil, "the window waits off screen for content that cannot come")
        #expect(WindowInvariants.problems(fixture.services.windows).isEmpty, "\(WindowInvariants.problems(fixture.services.windows))")
        let row = try await fixture.row()
        #expect(row?.machineID == MachineID("vm-absent"))
        #expect(row?.stage == CloudWorkspaceAbsence.signedOut.rowStatus)
        #expect(row?.isClosable == false, "a close waits for the machine")
    }

    /// Its machine listed but paused: the window offers Resume Machine.
    @Test func aWorkspaceOnAPausedMachineShowsResume() throws {
        let fixture = try Self.fixture(signedIn: true, pausedMachine: true)
        defer { fixture.close() }
        #expect(fixture.controller.shownCloudAbsence?.absence == .paused)
        #expect(fixture.controller.shownCloudAbsence?.absence.action == .resume)
    }

    /// The kept workspace's machine is not saved with its space, so its row shows only in the
    /// window's default space, not in every space of the window.
    @Test func aKeptWorkspaceRowShowsOnlyInTheDefaultSpace() async throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        _ = try await fixture.row()
        #expect(!fixture.controller.sidebar.absentCloudRows(fixture.controller.state).rows.isEmpty)
        fixture.controller.state.enterProfile(ProfileID(rawValue: "room-other"))
        #expect(fixture.controller.sidebar.absentCloudRows(fixture.controller.state).rows.isEmpty,
                "a kept Cloud workspace's row shows in a space it may not belong to")
    }

    // MARK: Fixture

    struct Fixture {
        let services: AppServices
        let controller: WindowController

        func close() {
            controller.teardown()
            controller.window?.close()
        }

        /// The kept workspace's sidebar row once the sidebar lists it (nil after 10 s).
        func row() async throws -> SidebarWorkspace? {
            let id = WorkspaceID(CloudWorkspaceAbsentDisplayTests.workspace)
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline, controller.sidebar.model.workspace(id) == nil { try await Task.sleep(for: .milliseconds(50)) }
            return controller.sidebar.model.workspace(id)
        }
    }

    /// One window, saved with only `workspace` on Cloud machine `vm-absent`; this Mac's tree loaded.
    /// `signedIn` gives a signed-in account with its list loaded (tests cannot sign in);
    /// `pausedMachine` lists the machine, paused.
    static func fixture(signedIn: Bool = false, pausedMachine: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        services.machines.local.store.apply(snapshot: DaemonTree(registryID: "s-local"))
        if signedIn {
            services.windows.cloudList = { _ in
                CloudService.ListFacts(isSignedIn: true, isRestoring: false, hasLoadedMachines: true, hasLoadedCurrentMachines: true)
            }
        } else {
            try #require(!services.cloud.isSignedIn && !services.cloud.auth.isRestoring, "the test runs signed out")
        }
        if pausedMachine { _ = CloudWorkspaceRestoreTests.pausedMachine(services, id: "vm-absent") }
        var record = WindowRecord(id: "w-absent", workspaceKey: WorkspaceKey(rawValue: workspace),
                                  workspaceKeys: [WorkspaceKey(rawValue: workspace)], machine: "vm-absent")
        record.workspaceMachines = [workspace: "vm-absent"]
        let document = WindowStateDocument(windows: [record])
        services.windows.rememberMachines(of: document)
        services.windows.states[record.id] = WindowState(record: record)
        _ = services.windows.registry.apply { registry in
            registry = WindowRegistry(records: document.windows)
            return WindowRegistry.Changes()
        }
        let window = try #require(services.windows.registry.value.window(record.id))
        let controller = services.windows.makeController(for: window)
        return Fixture(services: services, controller: controller)
    }
}
