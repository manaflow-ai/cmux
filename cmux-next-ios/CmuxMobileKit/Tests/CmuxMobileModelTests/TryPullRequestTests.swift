import Foundation
import Testing
@testable import CmuxMobileModel

@MainActor
@Suite struct TryPullRequestTests {
    @Test func theListReadsTryShsJSON() throws {
        let json = #"{"schema":"cmux.ios-try.list.v1","prs":[{"number":3,"title":"Spring insert","author":"a","head":"abc","updated_at":"2026-11-23T03:00:00Z","draft":true,"build":"ahead"},{"number":0,"title":"bad"},{"number":5,"title":"Old","build":"weird"}]}"#
        let list = try #require(TryPullRequestList.decode(Data(json.utf8)))
        #expect(list.error == nil)
        #expect(list.prs.map(\.number) == [3, 5])
        #expect(list.prs[0].build == .ahead && list.prs[0].build.ready && list.prs[0].draft)
        #expect(list.prs[0].updatedAt != nil)
        #expect(list.prs[1].build == TryPullRequest.Build.none)
        let failed = try #require(TryPullRequestList.decode(Data(#"{"error":"gh is not signed in","prs":[]}"#.utf8)))
        #expect(failed.error == "gh is not signed in" && failed.prs.isEmpty)
        #expect(TryPullRequestList.decode(Data("[]".utf8)) == nil)
    }

    @Test func withNoLinkTheListIsUnreachable() async {
        let model = TryPullRequestModel(macID: "mac", service: nil)
        await model.reload()
        #expect(model.load == .unreachable)
    }

    @Test func installFramesRead() {
        #expect(TryInstallEvent.decode(Data(#"{"line":"try: installed"}"#.utf8)) == .line("try: installed"))
        #expect(TryInstallEvent.decode(Data(#"{"done":true,"pr":3,"exit":0}"#.utf8)) == .done(exit: 0))
        #expect(TryInstallEvent.decode(Data("{}".utf8)) == nil)
    }

    final class FakeService: TryPullRequestService {
        var events: [TryInstallEvent] = []
        var status: TryInstallStatus?
        var installs: [Int] = []
        func tryPullRequests(macID: String) async throws -> TryPullRequestList {
            TryPullRequestList(prs: [TryPullRequest(number: 7, title: "x", build: .ahead)])
        }
        func tryInstallStatus(macID: String) async throws -> TryInstallStatus? { status }
        func installPullRequest(macID: String, number: Int) -> AsyncThrowingStream<TryInstallEvent, any Error> {
            installs.append(number)
            let events = events
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    @Test func theModelLoadsAndFollowsAnInstall() async {
        let service = FakeService()
        let model = TryPullRequestModel(macID: "m", service: service)
        await model.reload()
        #expect(model.load == .loaded(TryPullRequestList(prs: [TryPullRequest(number: 7, title: "x", build: .ahead)])))
        service.events = (1...10).map { .line("l\($0)") } + [.done(exit: 0)]
        await model.start(7)
        #expect(model.install == .finished(number: 7, exit: 0, lines: (3...10).map { "l\($0)" }))
        // The channel ending before `done` (the app being replaced) is not a success.
        service.events = [.line("installing")]
        await model.start(7)
        #expect(model.install == .failed(number: 7, message: "The Mac stopped answering before the install ended.", lines: ["installing"]))
    }

    @Test func statusFramesRead() {
        let lines = (1...70).map { "\"l\($0)\"" }.joined(separator: ",")
        let done = TryInstallStatus.decode(Data(#"{"run":{"pr":3,"started_ms":1,"lines":[\#(lines)],"exit":0}}"#.utf8))
        #expect(done == TryInstallStatus(number: 3, lines: (63...70).map { "l\($0)" }, exit: 0))
        #expect(TryInstallStatus.decode(Data(#"{"run":{"pr":3,"started_ms":1,"lines":[]}}"#.utf8))?.exit == nil)
        #expect(TryInstallStatus.decode(Data(#"{"run":null}"#.utf8)) == nil)
    }

    // #51721 F3: the app an install replaced reads the Mac's last install on relaunch.
    @Test func theRelaunchedPageShowsTheLastInstall() async {
        let service = FakeService()
        service.status = TryInstallStatus(number: 7, lines: ["try: installed"], exit: 0)
        let finished = TryPullRequestModel(macID: "m", service: service)
        await finished.resume()
        #expect(finished.install == .finished(number: 7, exit: 0, lines: ["try: installed"]))
        #expect(service.installs.isEmpty)
        // Still running: the page joins it and follows it to the end.
        service.status = TryInstallStatus(number: 8, lines: ["building"])
        service.events = [.line("building"), .line("installed"), .done(exit: 0)]
        let running = TryPullRequestModel(macID: "m", service: service)
        await running.resume()
        #expect(service.installs == [8])
        #expect(running.install == .finished(number: 8, exit: 0, lines: ["building", "installed"]))
        // No install on the Mac: nothing to show.
        service.status = nil
        let none = TryPullRequestModel(macID: "m", service: service)
        await none.resume()
        #expect(none.install == .idle)
    }
}
