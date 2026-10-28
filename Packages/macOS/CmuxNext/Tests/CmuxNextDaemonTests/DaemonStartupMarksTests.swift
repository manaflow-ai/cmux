import Foundation
import Testing
@testable import CmuxNextDaemon

/// The daemon's own start (`identify {startup_marks: true}`, `startup-marks-v1`) decodes into
/// `daemon.<step>` launch marks at the daemon's times, tolerates older and newer daemons, and is asked for only with
/// the flag the daemon reads.
struct DaemonStartupMarksTests {
    private static let origin: UInt64 = 1_700_000_000_000_000

    private func decode(_ json: String) throws -> DaemonStartupMarksRequest.Response {
        try JSONDecoder().decode(DaemonStartupMarksRequest.Response.self, from: Data(json.utf8))
    }

    @Test("Each reached step is a daemon mark at main_start plus its offset, in the daemon's start order")
    func stepsBecomeDaemonMarks() throws {
        let response = try decode("""
        {"startup_marks":{"first_identify_served":9000,"main_start_unix_us":\(Self.origin),\
        "config_loaded":1000,"mux_restored":5000}}
        """)
        let marks = try #require(response.startupMarks)
        let start = Date(timeIntervalSince1970: Double(Self.origin) / 1_000_000)
        #expect(marks.mainStart == start)
        #expect(marks.launchMarks.map(\.name)
            == ["daemon.main_start", "daemon.config_loaded", "daemon.mux_restored", "daemon.first_identify_served"])
        let offsets = marks.launchMarks.map { ($0.date.timeIntervalSince(start) * 1_000_000).rounded() }
        #expect(offsets == [0, 1000, 5000, 9000])
    }

    @Test("A step this build does not know is ignored; a mux no daemon serves reports none")
    func olderAndNewerDaemonsDecode() throws {
        let newer = try decode("""
        {"startup_marks":{"main_start_unix_us":\(Self.origin),"socket_bound":10,"future_step":20}}
        """)
        #expect(newer.startupMarks?.launchMarks.map(\.name) == ["daemon.main_start", "daemon.socket_bound"])
        #expect(try decode(#"{"startup_marks":null}"#).startupMarks == nil)
        // An older daemon ignores the flag and answers a plain identify.
        #expect(try decode(#"{"app":"cmux-tui","protocol":12}"#).startupMarks == nil)
    }

    @Test("Every daemon mark has its own code in the launch timings ring")
    func everyStepHasARingCode() {
        let names = [DaemonStartupMarks.mainStartMarkName] + DaemonStartupMarks.Step.allCases.map(\.markName)
        let codes = names.map(DaemonLaunchTimings.Step.traceCode(of:))
        #expect(!codes.contains(0))
        #expect(Set(codes).count == names.count)
    }

    @Test("The request is identify with startup_marks, refused before a daemon without startup-marks-v1")
    func requestShape() throws {
        let line = try WireCoding.encodeRequest(DaemonStartupMarksRequest(), id: 7)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["cmd"] as? String == "identify")
        #expect(object["startup_marks"] as? Bool == true)
        let old = DaemonIdentity(generation: DaemonGeneration(rawValue: "old"))
        #expect(throws: DaemonError.self) { try DaemonStartupMarksRequest.requireServed(by: old) }
        let current = DaemonIdentity(capabilities: ["startup-marks-v1"], generation: DaemonGeneration(rawValue: "new"))
        #expect(throws: Never.self) { try DaemonStartupMarksRequest.requireServed(by: current) }
    }
}
