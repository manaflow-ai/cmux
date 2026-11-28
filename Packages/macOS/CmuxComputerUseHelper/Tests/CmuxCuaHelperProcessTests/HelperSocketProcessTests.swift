// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

/// The built helper as a real process: runs
/// scripts/cmux-next/tests/cua-helper-socket.test.sh, which starts
/// `cmux-cua-helper` with a control pipe (as the cmux app does) and drives
/// its socket from a second process. No in-process call on a helper type.
/// This target exists so the fleet's package lane (cmux-ci, package-test-lane.sh
/// suite) can run the script against the binary it just built.
@Suite struct HelperSocketProcessTests {
    @Test(.timeLimit(.minutes(2))) func socketLocationAndPeerChecksHoldForTheBuiltHelper() throws {
        let executable = try #require(Self.helperExecutable(), "the built cmux-cua-helper")
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appending(path: "scripts/cmux-next/tests/cua-helper-socket.test.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, executable]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        print(text)
        #expect(process.terminationStatus == 0, "\(text)")
    }

    /// The built `cmux-cua-helper`: beside a loaded .xctest bundle, else in
    /// this package's .build/<triple>/debug.
    static func helperExecutable() -> String? {
        var candidates = (Bundle.allBundles + Bundle.allFrameworks).map(\.bundleURL)
            .filter { $0.pathExtension == "xctest" }
            .map { $0.deletingLastPathComponent().appending(path: "cmux-cua-helper").path }
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = package.appending(path: ".build")
        candidates.append(build.appending(path: "debug/cmux-cua-helper").path)
        for triple in (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? [] {
            candidates.append(build.appending(path: "\(triple)/debug/cmux-cua-helper").path)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
