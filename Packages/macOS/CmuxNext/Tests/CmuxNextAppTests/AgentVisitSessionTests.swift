import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing
@testable import CmuxNextApp

/// RFD 0125 D5: "Every visit carries its actor: the person, or an agent and its session." The visits an agent's page
/// loads named the agent but not its session (`sessionID: nil`), so a session's web trail (D11) could not be read back.
@Suite struct AgentVisitSessionMarksTests {
    @Test func aSurfaceAnAgentOpenedHandsItsSessionToItsTab() {
        var marks = TabAgentMarks()
        let surface = SurfaceID(rawValue: 7)
        marks.mark(surface: surface, session: "sess-a")
        marks.claim(surface: surface, key: "tab-1", pane: nil, machine: "", hasPage: false)
        #expect(marks.tabs.contains("tab-1"))
        #expect(marks.sessions["tab-1"] == "sess-a")
        #expect(!marks.surfaces.contains(surface))
    }

    @Test func aSurfaceWithNoSessionStillMarksItsTab() {
        var marks = TabAgentMarks()
        let surface = SurfaceID(rawValue: 8)
        marks.mark(surface: surface, session: nil)
        marks.claim(surface: surface, key: "tab-2", pane: nil, machine: "", hasPage: false)
        #expect(marks.tabs.contains("tab-2"))
        #expect(marks.sessions["tab-2"] == nil)
    }

    @Test func anUnclaimedSessionIsDroppedWithItsSurfaceAndAClosedTabForgetsIt() {
        var marks = TabAgentMarks()
        let surface = SurfaceID(rawValue: 9)
        marks.mark(surface: surface, session: "sess-b")
        // The page already existed: no mark, and the session does not wait for a later tab of that surface.
        marks.claim(surface: surface, key: "tab-3", pane: nil, machine: "", hasPage: true)
        #expect(marks.sessions["tab-3"] == nil)
        marks.claim(surface: surface, key: "tab-3", pane: nil, machine: "", hasPage: false)
        #expect(marks.sessions["tab-3"] == nil)
        marks.tabs.insert("tab-4")
        marks.sessions["tab-4"] = "sess-c"
        marks.forget("tab-4")
        #expect(marks.sessions["tab-4"] == nil)
    }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentVisitSessionAppTests {
    @Test func theSessionDrivingATabIsTheOneItsPageAndItsPopupsName() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try #require(services.windows.active?.focusedPane)
            let created = try await connection.newFrontendBrowserTab(url: "https://example.com/", engine: .webkit,
                                                                      in: pane.pane.handle, activate: true)
            try await PinnedPageTests.until({ services.daemon.store.tab(surface: created.surface) != nil }, report: {
                WindowStateReport.describe(services, surface: created.surface)
            })
            let model = try #require(services.daemon.store.tab(surface: created.surface))
            let controller = try #require(services.paneController(for: pane.pane))
            try await PinnedPageTests.until({ pane.pane.tabs.contains { $0.id == model.id } })
            controller.select(TabID(model.id), source: .intent)
            try await PinnedPageTests.until({ services.cache.existingBrowser(model.id) != nil }, report: {
                WindowStateReport.describe(services, surface: created.surface)
            })
            let opener = try #require(services.cache.existingBrowser(model.id)?.tab)
            defer { services.popups.closeAll() }

            // A call with no agent session marks the tab and names none.
            _ = AppBrowserPage.markAgentDriven(model.id, services: services)
            #expect(services.cache.agentMarks.sessions[model.id] == nil)

            // The browser call's caller session (BrowserPageService.intending binds it) is the tab's from then on.
            await BrowserPageIntent.$agentSession.withValue("sess-1") { @MainActor in
                _ = AppBrowserPage.markAgentDriven(model.id, services: services)
            }
            #expect(services.cache.agentMarks.sessions[model.id] == "sess-1")

            // Another session takes the tab over: its visits name that one.
            await BrowserPageIntent.$agentSession.withValue("sess-2") { @MainActor in
                _ = AppBrowserPage.markAgentDriven(model.id, services: services)
            }
            #expect(services.cache.agentMarks.sessions[model.id] == "sess-2")
            #expect(opener.agentSessionID == nil || opener.agentSessionID == "sess-2",
                    "a WebKit page is never agent-driven; a Chromium page names the latest session")
        }
    }
}
