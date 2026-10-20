import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Open All Workspace PR Links (`palette.openWorkspacePullRequests`,
/// `cmux workspace open-all-pr-links`): the links come from the workspace's
/// status entries (`cmux workspace status set pr <text>` first), each web
/// link once, and the action runs instead of showing a greyed-out reason.
@MainActor @Suite(.serialized)
struct WorkspacePullRequestLinksTests {
    @Test func linksComeFromThePullRequestEntryFirstAndEachOnce() {
        let entries = [
            WorkspaceStatus.Entry(key: "build", text: "CI https://github.com/o/r/actions/runs/1 green"),
            WorkspaceStatus.Entry(key: "pr", text: "#12 https://github.com/o/r/pull/12 and https://github.com/o/r/pull/13"),
            WorkspaceStatus.Entry(key: "note", text: "see https://github.com/o/r/pull/12 again, mailto:a@b.c, file:///tmp/x"),
        ]
        let links = WorkspacePullRequestLinks(entries).urls.map(\.absoluteString)
        #expect(links == [
            "https://github.com/o/r/pull/12",
            "https://github.com/o/r/pull/13",
            "https://github.com/o/r/actions/runs/1",
        ])
    }

    @Test func aWorkspaceWithoutLinksHasNone() {
        #expect(WorkspacePullRequestLinks([WorkspaceStatus.Entry(key: "pr", text: "#12 open")]).urls.isEmpty)
        #expect(WorkspacePullRequestLinks([]).urls.isEmpty)
    }

    @Test func openAllWorkspacePRLinksIsAvailableAndSaysWhyWhenItCannotRun() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "palette.openWorkspacePullRequests") == nil,
                "Open All Workspace PR Links is still greyed out")
        // No workspace to act on here: a reason, never a silent no-op.
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("palette.openWorkspacePullRequests", invocation: ActionInvocation())
        }
        #expect(refusal != nil)
    }
}
