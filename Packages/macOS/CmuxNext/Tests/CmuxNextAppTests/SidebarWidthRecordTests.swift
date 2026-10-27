import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing

/// p06-scheduler-302 (R-obs, services): the sidebar's width record is a `ServiceObservation`, not a
/// view's. It writes the window's state, which the window record and other owners read, so it has no
/// visibility node: a change still writes while the sidebar is hidden and no window is on screen
/// (p06 rule 3), and the person's own change writes in the input-response pass, before the commit
/// (rule 2). It starts in `restore(width:hidden:)`, so the default width never lands over the saved one.
@MainActor @Suite(.serialized)
struct SidebarWidthRecordTests {
    private static func window() throws -> WindowState {
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"width-record","workspace_key":"width-record-home"}"#.utf8))
        return WindowState(record: record)
    }

    /// One window's sidebar on a scheduler with no display link (a post runs on the next main run loop pass).
    private static func sidebar() throws -> (AppServices, WindowState, SidebarBridge) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: linklessMainWork())
        let state = try window()
        return (services, state, SidebarBridge(services: services, state: state))
    }

    private static let widths = (SidebarModel.widthRange.lowerBound + 10, SidebarModel.widthRange.lowerBound + 20,
                                 SidebarModel.widthRange.lowerBound + 30)

    @Test func theRestoredWidthIsTheFirstValueRecorded() throws {
        let (_, state, bridge) = try Self.sidebar()
        defer { bridge.teardown() }
        #expect(state.sidebarWidth == nil, "the default width was recorded before the saved one was restored")
        bridge.restore(width: Double(Self.widths.0), hidden: true)
        #expect(state.sidebarWidth == Double(Self.widths.0), "restore did not record the restored width in its own turn")
        #expect(state.sidebarHidden)
    }

    @Test func aWidthChangeIsRecordedWhileTheSidebarIsHidden() async throws {
        let (services, state, bridge) = try Self.sidebar()
        defer { bridge.teardown() }
        bridge.restore(width: Double(Self.widths.0), hidden: true)
        services.mainWork.causes.withCause(.automation) { bridge.model.width = Self.widths.1 }
        #expect(state.sidebarWidth == Double(Self.widths.0), "the record wrote inside the change's will-set")
        await drainMainTurns()
        #expect(state.sidebarWidth == Double(Self.widths.1), "a hidden sidebar's width change was not recorded")
        #expect(state.sidebarHidden, "the record lost the hidden presentation")
    }

    @Test func aPersonsWidthChangeIsRecordedInTheInputResponsePass() async throws {
        let (services, state, bridge) = try Self.sidebar()
        defer { bridge.teardown() }
        bridge.restore(width: Double(Self.widths.0), hidden: false)
        let causes = services.mainWork.causes
        causes.withCause(.person) { bridge.model.width = Self.widths.2 }
        #expect(causes.flushPersonCaused() >= 1, "the person's width change did not reach the input-response pass")
        #expect(state.sidebarWidth == Double(Self.widths.2), "the person's width was not recorded before the commit")
        await drainMainTurns()
        #expect(state.sidebarWidth == Double(Self.widths.2))
    }
}
