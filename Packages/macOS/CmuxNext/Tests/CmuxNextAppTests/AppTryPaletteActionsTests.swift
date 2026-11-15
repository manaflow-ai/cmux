import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextUpdater
import Testing

/// Run a PR as This App… and Undo Last PR Run (Leo, 2026-11-14: "How deep and fast and ergonomic is
/// hot swapping and can we push it further and productionize it further"): two palette rows side by
/// side in Settings, whose CLI stays `cmux app try`, and which run exactly `app try <target>` and
/// `app try undo` on the bundled CLI.
@MainActor
struct AppTryPaletteActionsTests {
    @Test func bothAreSettingsPaletteRowsSideBySideThatKeepTheirOwnersCLIVerb() throws {
        let all = ActionCatalog.all
        let run = try #require(all.firstIndex { $0.id == AppTryActions.runID }, "Run a PR as This App… is in the catalog")
        let undo = try #require(all.firstIndex { $0.id == AppTryActions.undoID }, "Undo Last PR Run is in the catalog")
        #expect(undo == run + 1, "the undo row sits right after the run row")
        #expect(all[run - 1].id == "updates.installEarlierBuild", "next to the other build-switching rows")
        for descriptor in [all[run], all[undo]] {
            #expect(descriptor.isPaletteVisible, "\(descriptor.id) is a palette row")
            #expect(descriptor.category == all[run - 1].category, "\(descriptor.id) is in the same category as its neighbours")
            #expect(descriptor.surfacePlan.cli == .exempt(.ownerVerb), "\(descriptor.id): the CLI is `cmux app try`")
        }
        #expect(all[run].hint != nil, "the run row says what it does under its title")
    }

    @Test func runAsksForThePullRequestBranchOrCommitAndUndoAsksNothing() throws {
        let run = try #require(ActionCatalog.all.first { $0.id == AppTryActions.runID })
        #expect(run.arguments.map(\.name) == ["target"])
        #expect(run.arguments.map(\.isRequired) == [true], "the palette asks for it")
        let undo = try #require(ActionCatalog.all.first { $0.id == AppTryActions.undoID })
        #expect(undo.arguments.isEmpty)
    }

    @Test func eachRunsItsCLIVerb() {
        #expect(AppTryActions.arguments(for: AppTryActions.runID, target: " 43540 \n") == ["app", "try", "43540"])
        #expect(AppTryActions.arguments(for: AppTryActions.runID, target: "feat-cmux-next") == ["app", "try", "feat-cmux-next"])
        #expect(AppTryActions.arguments(for: AppTryActions.runID, target: "   ") == nil, "an empty answer runs nothing")
        #expect(AppTryActions.arguments(for: AppTryActions.runID, target: nil) == nil)
        #expect(AppTryActions.arguments(for: AppTryActions.undoID, target: nil) == ["app", "try", "undo"])
        #expect(AppTryActions.arguments(for: "updates.rollback", target: "1") == nil)
    }

    @Test func bothAreBound() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        for id in [AppTryActions.runID, AppTryActions.undoID] {
            #expect(services.registry.action(for: id) != nil, "\(id) has a handler")
        }
    }
}
