import AppKit
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// `debug.home` goes into a capture's report as each step's answer, and the capture's privacy check refuses a path
/// under the capture account's home (the Chief owner's home and its cache file are such paths). By default the
/// answer names no path; a script that needs them asks for them.
@MainActor @Suite(.serialized)
struct DebugHomePrivacyTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// Every string in `value`, at any depth.
    static func strings(_ value: CmuxNextSettings.JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .array(let items): items.flatMap(strings)
        case .object(let fields): fields.values.flatMap(strings)
        default: []
        }
    }

    @Test func theDefaultAnswerNamesNoPath() throws {
        guard case .object(let report) = DebugHome.report(services: Self.services()),
              case .object(let owner)? = report["chief_owner"] else {
            Issue.record("debug.home answered no chief_owner object")
            return
        }
        #expect(owner["home"] == nil)
        #expect(owner["cache"] == nil)
        #expect(owner["session"] != nil)
        let paths = Self.strings(.object(report)).filter { $0.hasPrefix("/") }
        #expect(paths.isEmpty, "debug.home names paths: \(paths)")
    }

    @Test func aScriptThatAsksGetsTheOwnersHome() throws {
        guard case .object(let report) = DebugHome.report(services: Self.services(), paths: true),
              case .object(let owner)? = report["chief_owner"] else {
            Issue.record("debug.home answered no chief_owner object")
            return
        }
        #expect(owner["home"]?.stringValue?.hasPrefix("/") == true)
        #expect(owner.keys.contains("cache"))
    }
}
