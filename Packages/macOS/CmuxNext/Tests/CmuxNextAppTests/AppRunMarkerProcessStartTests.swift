@testable import CmuxNextApp
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// `run.json` carries the run's kernel process start, the value its black box and
/// crash-key page headers carry, so the next launch puts only that process's files on its crash event.
struct AppRunMarkerProcessStartTests {
    @Test func theProcessStartRoundTripsThroughRunJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "process-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: false,
                              survived: true, signal: nil, quitting: false, bootSession: nil,
                              processStart: 1_790_000_000_250_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(run).write(to: directory.appending(path: "run.json"))
        let read = try #require(AppRunMarker.readPrevious(marker: directory.appending(path: "run.json"),
                                                          signal: directory.appending(path: "run.signal")))
        #expect(read.processStart == 1_790_000_000_250_000)
    }

    /// A marker written before the field reads with no process start: the next launch then checks the pid only.
    @Test func anOlderMarkerHasNoProcessStart() throws {
        let json = #"{"pid":4242,"launched":1790000000,"recovery":false,"survived":true}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let run = try decoder.decode(PreviousRun.self, from: Data(json.utf8))
        #expect(run.processStart == nil)
    }

    /// The launch read writes this process's start into the run's marker, so the next launch can match the files.
    @Test func theLaunchReadStoresThisProcessStart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "process-start-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = AppRunMarker.prepareLaunch(directory: directory, now: Date(), bootSession: nil)
        if launch.signalDescriptor >= 0 { close(launch.signalDescriptor) }
        if launch.keysDescriptor >= 0 { close(launch.keysDescriptor) }
        #expect(launch.failure == nil)
        #expect(launch.marker.processStart != nil)
        #expect(launch.marker.processStart == AppRunMarker.currentProcessStart())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(PreviousRun.self, from: AppRunMarker.encode(launch.marker))
        #expect(decoded.processStart == launch.marker.processStart)
    }

    @Test func theProcessStartIsTheRingHeadersValue() {
        let start = AppRunMarker.currentProcessStart()
        #expect(start != nil)
        #expect(start == TraceBlackBox.ProcessFacts.current().processStartUnixMicros)
    }
}
