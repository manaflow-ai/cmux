import Foundation
import Testing
@testable import CmuxNextMobile

@Suite struct MobileHostLogTests {
    @Test(arguments: [0, 1 << 20])
    func reopeningAppendsThroughTheRotationBoundary(size: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("cmux-mobile-host.log")
        let before = Data(repeating: 65, count: size)
        try before.write(to: log)
        let handle = try #require(MobileHostProcess.logHandle(log))
        try handle.write(contentsOf: Data("after restart\n".utf8))
        try handle.close()
        #expect(try Data(contentsOf: log) == before + Data("after restart\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: log.path + ".1"))
    }

    @Test func oversizedLogSurvivesStartupAndTheNextRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("cmux-mobile-host.log")
        let previous = log.appendingPathExtension("1")
        let incident = Data(repeating: 65, count: (1 << 20) + 1)
        try incident.write(to: log)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        let first = try #require(MobileHostProcess.logHandle(log))
        let next = Data(repeating: 66, count: (1 << 20) + 1)
        try first.write(contentsOf: next)
        try first.close()
        #expect(try Data(contentsOf: previous) == incident)
        #expect(try Data(contentsOf: log) == next)
        let second = try #require(MobileHostProcess.logHandle(log))
        try second.write(contentsOf: Data("new start\n".utf8))
        try second.close()
        #expect(try Data(contentsOf: previous) == next)
        #expect(try Data(contentsOf: log) == Data("new start\n".utf8))
        for file in [log, previous] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func failedRotationKeepsAndAppendsTheCurrentEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("cmux-mobile-host.log")
        let incident = Data(repeating: 65, count: (1 << 20) + 1)
        try incident.write(to: log)
        // A directory cannot be replaced by the log file, even when tests run as root.
        try FileManager.default.createDirectory(at: log.appendingPathExtension("1"), withIntermediateDirectories: true)
        let handle = try #require(MobileHostProcess.logHandle(log))
        try handle.write(contentsOf: Data("rotation refused\n".utf8))
        try handle.close()
        #expect(try Data(contentsOf: log) == incident + Data("rotation refused\n".utf8))
    }
}
