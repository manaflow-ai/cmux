import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The Mac's long jobs on the phone (plans/cmux-next/long-jobs-DESIGN.md, issue 13742) at the daemon
/// channel's boundary: a Mac whose cmux-tui serves `long_jobs` is asked `jobs-list` once after the setup
/// (no params), a `jobs-changed` event replaces the list, a `jobs-list` reply older than an event is dropped,
/// and a Mac without the capability is never asked and shows none.
@MainActor
@Suite struct MacLongJobsLiveTests {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [[String: Any]] = []
        func add(_ object: [String: Any]) { lock.withLock { lines.append(object) } }
        var commands: [[String: Any]] { lock.withLock { lines } }
    }

    nonisolated static func job(_ id: String, done: Int, total: Int, blocks: String = #""startup""#) -> String {
        #"{"id":"\#(id)","kind":"registry.output_cleanup","title":"Cleaning up stored terminal output","detail":"pack segments","done":\#(done),"total":\#(total),"started_ms":1,"updated_ms":2,"blocks":[\#(blocks)],"cancellable":false}"#
    }

    /// `eventFirst`: the daemon sends a `jobs-changed` before its `jobs-list` reply (the reply is then older).
    nonisolated static func daemon(_ seen: Seen, servesLongJobs: Bool, eventFirst: Bool = false) -> MockMacLink {
        MockMacLink { _, data in
            data.split(separator: 0x0A).flatMap { request -> [Data] in
                guard let object = try? JSONSerialization.jsonObject(with: Data(request)) as? [String: Any],
                      let id = object["id"] as? String else { return [] }
                seen.add(object)
                func line(_ text: String) -> Data { Data(text.utf8) + Data([0x0A]) }
                switch object["cmd"] as? String ?? "" {
                case "identify":
                    let capabilities = servesLongJobs ? #"["long_jobs"]"# : "[]"
                    return [line(#"{"id":"\#(id)","ok":true,"data":{"app":"cmux-tui","protocol":12,"version":"1","capabilities":\#(capabilities)}}"#)]
                case "list-workspaces":
                    return [line(#"{"id":"\#(id)","ok":true,"data":{"workspaces":[]}}"#)]
                case "list-agents":
                    return [line(#"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#)]
                case "jobs-list":
                    let reply = line(#"{"id":"\#(id)","ok":true,"data":{"jobs":[\#(job("a", done: 100, total: 1000))]}}"#)
                    let event = line(#"{"event":"jobs-changed","jobs":[\#(job("a", done: 430, total: 1000))]}"#)
                    return eventFirst ? [event, reply] : [reply, event]
                default:
                    return [line(#"{"id":"\#(id)","ok":true,"data":{}}"#)]
                }
            }
        }
    }

    func bound(_ link: MockMacLink) async throws -> WorkspaceSync {
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        await sync.bind(try await link.openChannel(service: "daemon", args: [:]), macID: "m")
        return sync
    }

    @Test(arguments: [false, true])
    func aMacThatServesLongJobsShowsTheNewestList(eventFirst: Bool) async throws {
        let seen = Seen()
        let sync = try await bound(Self.daemon(seen, servesLongJobs: true, eventFirst: eventFirst))
        var shown: [[MacLongJob]] = []
        sync.onLongJobs = { shown.append($0) }
        for _ in 0..<500 where sync.longJobs.first?.percent != 43 { await Task.yield() }
        #expect(sync.longJobs.map(\.id) == ["a"])
        #expect(sync.longJobs.first?.percent == 43, "the newest list is the event's (43%)")
        #expect(sync.longJobs.first?.summary == "Cleaning up stored terminal output 43%")
        // An older reply never replaces the event's list.
        for _ in 0..<50 { await Task.yield() }
        #expect(sync.longJobs.first?.percent == 43)
        let asked = try #require(seen.commands.first { $0["cmd"] as? String == "jobs-list" })
        #expect(Set(asked.keys) == ["id", "cmd"], "jobs-list carries no params")
        #expect(seen.commands.filter { $0["cmd"] as? String == "jobs-list" }.count == 1)

        // The jobs end: an empty list hides the bar.
        sync.handleLongJobs([])
        #expect(sync.longJobs.isEmpty)
        #expect(shown.last == [])
    }

    @Test func aMacWithoutLongJobsIsNeverAskedAndShowsNone() async throws {
        let seen = Seen()
        let sync = try await bound(Self.daemon(seen, servesLongJobs: false))
        for _ in 0..<50 { await Task.yield() }
        #expect(sync.longJobs.isEmpty)
        #expect(!seen.commands.contains { $0["cmd"] as? String == "jobs-list" })
    }

    @Test func theEventDecodesAndAJobWithoutAnIdIsSkipped() {
        let line = Data(#"{"event":"jobs-changed","jobs":[\#(Self.job("a", done: 1, total: 4)),{"kind":"registry.compact"}]}"#.utf8)
        guard case .longJobs(let jobs) = DaemonEvent.parse(line) else {
            Issue.record("jobs-changed did not decode")
            return
        }
        #expect(jobs.map(\.id) == ["a"])
        #expect(jobs.first?.percent == 25)
        #expect(jobs.first?.blocks == ["startup"])
    }
}
