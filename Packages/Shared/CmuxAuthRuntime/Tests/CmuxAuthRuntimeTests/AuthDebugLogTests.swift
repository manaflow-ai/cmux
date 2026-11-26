import Foundation
import Testing
@testable import CmuxAuthRuntime

@Suite struct AuthDebugLogTests {
    @Test func debugLogPathsIncludeTaggedDebugLogWhenConfigured() {
        #if DEBUG && os(macOS)
        let paths = AuthDebugLog.debugLogPaths(environment: [
            "CMUX_DEBUG_LOG": "/tmp/cmux-debug-safari.log",
        ])

        #expect(paths == ["/tmp/cmux-auth-debug.log", "/tmp/cmux-debug-safari.log"])
        #endif
    }

    #if DEBUG && os(macOS)
    @Test func debugLineIsNotWrittenThroughASymbolicLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        try Data("original\n".utf8).write(to: target)
        let log = directory.appendingPathComponent("cmux-auth-debug.log")
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: target)

        appendAuthDebugLineToFile("auth: line\n", path: log.path)

        #expect(try String(contentsOf: target, encoding: .utf8) == "original\n")
    }

    @Test func debugLineIsNotWrittenThroughAHardLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        try Data("original\n".utf8).write(to: target)
        let log = directory.appendingPathComponent("cmux-auth-debug.log")
        try FileManager.default.linkItem(at: target, to: log)

        appendAuthDebugLineToFile("auth: line\n", path: log.path)

        #expect(try String(contentsOf: target, encoding: .utf8) == "original\n")
    }

    @Test func debugLinesAppendToAPrivateLogFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("cmux-auth-debug.log")

        appendAuthDebugLineToFile("auth: first\n", path: log.path)
        appendAuthDebugLineToFile("auth: second\n", path: log.path)

        #expect(try String(contentsOf: log, encoding: .utf8) == "auth: first\nauth: second\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-auth-debug-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    #endif

    @Test func redactionCoversCallbackTokenQueryValues() {
        let redacted = AuthDebugLog.redacted(
            "auth.callback.complete url=cmux-dev://auth-callback?stack_refresh=refresh-secret&stack_access=access-secret&cmux_auth_state=state-secret"
        )

        #expect(redacted.contains("refresh-secret") == false)
        #expect(redacted.contains("access-secret") == false)
        #expect(redacted.contains("state-secret") == false)
        #expect(redacted.contains("stack_refresh=<redacted>"))
        #expect(redacted.contains("stack_access=<redacted>"))
        #expect(redacted.contains("cmux_auth_state=<redacted>"))
    }

    @Test func redactionCoversEncodedNestedCallbackState() {
        let redacted = AuthDebugLog.redacted(
            "auth.browser.session.create signInURL=http://localhost:4577/handler/native-sign-in?after_auth_return_to=http%3A%2F%2Flocalhost%3A4577%2Fhandler%2Fafter-sign-in%3Fnative_app_return_to%3Dcmux-dev-safauth%253A%252F%252Fauth-callback%253Fcmux_auth_state%253Dstate-secret"
        )

        #expect(redacted.contains("state-secret") == false)
        #expect(redacted.contains("cmux_auth_state%253D<redacted>"))
    }
}
