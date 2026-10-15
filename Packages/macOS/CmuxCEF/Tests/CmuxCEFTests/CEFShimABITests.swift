import Foundation
import Testing
@testable import CmuxCEF

/// The shim ABI identity is the SHA-256 of the shim header, derived the same
/// way on both sides, so an interface change needs no hand-bumped number.
@Suite struct CEFShimABITests {
    static let header = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CmuxCEF/Shim/cmux_cef_shim.h")

    /// The bundled resource is the header in the source tree.
    @Test func bundledIdentityIsTheSourceHeaderHash() throws {
        let source = try Data(contentsOf: Self.header)
        #expect(CEFShimABI.bundledIdentity() == CEFShimABI.identity(of: source))
    }

    /// Swift's identity equals what build-cef-shim.sh compiles into the shim
    /// (`shasum -a 256 <header>`).
    @Test func identityMatchesTheBuildScriptDerivation() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", Self.header.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let shasum = try #require(output.split(separator: " ").first.map(String.init))
        #expect(CEFShimABI.bundledIdentity() == shasum)
        #expect(shasum.count == 64)
    }

    @Test func mismatchOrMissingIdentityRefusesTheShim() {
        #expect(throws: CEFShimLibrary.LoadError.abiMismatch(expected: "a", found: "b")) {
            try CEFShimLibrary.checkABI(expected: "a", found: "b")
        }
        #expect(throws: CEFShimLibrary.LoadError.abiMismatch(expected: "missing", found: "b")) {
            try CEFShimLibrary.checkABI(expected: nil, found: "b")
        }
        #expect(throws: Never.self) { try CEFShimLibrary.checkABI(expected: "a", found: "a") }
    }
}

@Suite struct CEFRuntimeLayoutTests {
    /// A bundle without the embedded runtime has no layout: the engine is
    /// reported as not bundled and nothing is loaded.
    @Test func missingRuntimeHasNoLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-cef-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CEFRuntimeLayout.locate(environment: ["CMUX_CEF_RUNTIME": dir.path]) == nil)
    }

    @Test func embeddedRuntimeResolvesTheBaseHelper() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cef-layout-\(UUID().uuidString)").appendingPathComponent("cmux DEV.app")
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        for item in [CEFRuntimeLayout.frameworkName, "cmux DEV Helper.app", "cmux DEV Helper (GPU).app"] {
            try FileManager.default.createDirectory(at: frameworks.appendingPathComponent(item), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: frameworks.appendingPathComponent(CEFRuntimeLayout.shimName).path, contents: Data())
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let layout = try #require(CEFRuntimeLayout.locate(environment: ["CMUX_CEF_RUNTIME": frameworks.path]))
        #expect(layout.helperApp.lastPathComponent == "cmux DEV Helper.app")
        #expect(layout.mainBundle.lastPathComponent == "cmux DEV.app")
        #expect(layout.helperExecutable.path.hasSuffix("cmux DEV Helper.app/Contents/MacOS/cmux DEV Helper"))
    }
}

@Suite struct CEFPumpScheduleTests {
    @Test func demandDrivenForkHasNoSafetyNet() {
        #expect(CEFPumpSchedule.safetyNet(forkAPIVersion: 23) == .none)
        #expect(CEFPumpSchedule.safetyNet(forkAPIVersion: 6) == CEFPumpSchedule.standard)
    }

    @Test func immediateRequestWakesNowAndDelayedRequestWaits() {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        #expect(schedule.nextWake == nil)
        schedule.request(milliseconds: 0, now: 10)
        #expect(schedule.nextWake?.deadline == -.infinity)
        let began = schedule.beginWork(now: 10)
        #expect(began)
        schedule.endWork(now: 10.001, elapsed: 0.001)
        #expect(schedule.nextWake == nil)
        schedule.request(milliseconds: 250, now: 20)
        #expect(schedule.nextWake?.deadline == 20.25)
    }
}

@Suite struct CEFShimEventTests {
    @Test func decodesLoadingStateBits() {
        let event = CEFShimEvent(kind: 7, browser: 3, request: 0, a: 0b101, b: 0, s1: "", s2: "")
        #expect(event == .loadingState(browser: 3, loading: true, canGoBack: false, canGoForward: true))
        #expect(event.browserID == 3)
    }

    @Test func processWideEventsHaveNoBrowser() {
        #expect(CEFShimEvent(kind: 1, browser: 0, request: 0, a: 0, b: 0, s1: "", s2: "").browserID == nil)
    }
}
