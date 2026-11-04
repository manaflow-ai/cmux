// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Foundation
import Testing

/// Discovery before approval (D21): the worker answers `list_apps` and
/// unscoped `list_windows` with metadata only under `ask`, and under
/// `bounded` for apps outside the owner's manifest. The desktop: Terminal
/// (pid 100, window 9000), TextEdit (102, 9001), Safari (103, 9003 and 9006),
/// 1Password (104, 9004), cmux (105, 9005), and a window of a pid that is no
/// regular app (999, 9010).
@Suite struct DesktopDiscoveryTests {
    static let ungrantedSafari = Data(#"{"pid":103}"#.utf8)

    @Test(.timeLimit(.minutes(1))) func askListsAppsWithoutUpstreamAndOmitsNeverAllowedApps() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        let result = try Self.parse(try await session.invoke(name: "list_apps", arguments: Data("{}".utf8)))
        try Self.expectNoTitles(result)
        #expect(fixture.driver.created().allSatisfy { $0.session.invoked.isEmpty }, "upstream refuses this; the worker answers")
        #expect(fixture.host.sent.withLock { $0.isEmpty }, "discovery never asks the person")
        let apps = try #require((result["structuredContent"] as? [String: Any])?["apps"] as? [[String: Any]])
        #expect(apps.map { $0["pid"] as? Int } == [103, 102], "Safari and TextEdit; Terminal, 1Password and cmux left out")
        #expect(Set(apps[1].keys) == ["pid", "name", "bundle_id", "running"])
        #expect(apps[1]["bundle_id"] as? String == "com.apple.TextEdit")
        let text = try Self.text(result)
        #expect(!text.contains("Terminal") && !text.contains("1Password") && !text.contains("cmux"))
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func askListsWindowsAsIDsAndOwnersOnly() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        let result = try Self.parse(try await session.invoke(name: "list_windows", arguments: Data("{}".utf8)))
        try Self.expectNoTitles(result)
        #expect(fixture.driver.created().allSatisfy { $0.session.invoked.isEmpty })
        let windows = try #require((result["structuredContent"] as? [String: Any])?["windows"] as? [[String: Any]])
        #expect(windows.map { $0["window_id"] as? Int } == [9001, 9003, 9006])
        #expect(Set(windows[0].keys) == ["window_id", "pid", "app_name", "bundle_id"], "no title, no bounds")
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func anUngrantedPidGetsMetadataAndAGrantedPidGoesUpstream() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        let before = try Self.parse(try await session.invoke(name: "list_windows", arguments: Self.ungrantedSafari))
        try Self.expectNoTitles(before)
        let windows = try #require((before["structuredContent"] as? [String: Any])?["windows"] as? [[String: Any]])
        #expect(windows.map { $0["window_id"] as? Int } == [9003, 9006], "only that pid's windows")
        #expect(fixture.host.sent.withLock { $0.isEmpty }, "no question for discovery")
        // TextEdit allowed for this session, through the real question.
        let click = Task { try await session.invoke(name: "click", arguments: SessionFixture.textEditClick) }
        fixture.answer(try await fixture.host.next(), "session")
        _ = try await click.value
        _ = try await session.invoke(name: "list_windows", arguments: Data(#"{"pid":102}"#.utf8))
        let created = fixture.driver.created()
        #expect(created.last?.session.invoked == ["click", "list_windows"], "the granted app's list is upstream's")
        _ = try await session.invoke(name: "list_windows", arguments: Self.ungrantedSafari)
        #expect(fixture.driver.created().last?.session.invoked == ["click", "list_windows"], "Safari stays metadata only")
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func aNeverAllowedPidIsRefusedNotListed() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        await #expect(throws: ToolError.self) {
            try await session.invoke(name: "list_windows", arguments: Data(#"{"pid":104}"#.utf8))
        }
        #expect(fixture.driver.created().allSatisfy { $0.session.invoked.isEmpty })
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func standardAndUnrestrictedModesAreUntouched() async throws {
        for mode in [ComputerUseMode.standard, .unrestricted] {
            let fixture = try SessionFixture(mode: mode)
            defer { fixture.cleanUp() }
            let session = try fixture.sessions.openSession()
            _ = try await session.invoke(name: "list_apps", arguments: Data("{}".utf8))
            _ = try await session.invoke(name: "list_windows", arguments: Data("{}".utf8))
            #expect(fixture.driver.created()[0].session.invoked == ["list_apps", "list_windows"])
            session.close()
        }
    }

    @Test(.timeLimit(.minutes(1))) func boundedAnswersOutsideTheOwnersAppsOnly() async throws {
        let owner = Data(#"{"version":3,"resources":{"apps":[{"bundle_id":"com.apple.TextEdit"}],"desktop":{"display":false}},"allow":{"tools":["list_windows"]}}"#.utf8)
        let fixture = try SessionFixture(mode: .bounded, ownerManifest: owner)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        try Self.expectNoTitles(try Self.parse(try await session.invoke(name: "list_apps", arguments: Data("{}".utf8))))
        try Self.expectNoTitles(try Self.parse(try await session.invoke(name: "list_windows", arguments: Self.ungrantedSafari)))
        #expect(fixture.driver.created()[0].session.invoked.isEmpty)
        _ = try await session.invoke(name: "list_windows", arguments: Data(#"{"pid":102}"#.utf8))
        #expect(fixture.driver.created()[0].session.invoked == ["list_windows"], "the owner's app: upstream answers")
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func boundedWithTheDisplayLeavesDiscoveryUpstream() async throws {
        let owner = Data(#"{"version":3,"resources":{"apps":[],"desktop":{"display":true}},"allow":{"tools":["list_apps"]}}"#.utf8)
        let fixture = try SessionFixture(mode: .bounded, ownerManifest: owner)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        _ = try await session.invoke(name: "list_apps", arguments: Data("{}".utf8))
        #expect(fixture.driver.created()[0].session.invoked == ["list_apps"])
        session.close()
    }

    @Test func ownerManifestFactsReadAppsAndDisplay() {
        let facts = OwnerManifestFacts(data: Data(#"{"resources":{"apps":[{"bundle_id":"COM.Apple.TextEdit"}]}}"#.utf8))
        #expect(facts == OwnerManifestFacts(bundleIDs: ["com.apple.textedit"], display: false))
        #expect(OwnerManifestFacts(data: Data("version: 3\n".utf8)) == nil, "YAML the worker cannot read: upstream decides")
    }

    // MARK: Helpers

    static func parse(_ data: Data) throws -> [String: Any] { try #require(HelperWire.object(data)) }

    static func text(_ result: [String: Any]) throws -> String {
        try #require(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
    }

    /// No title anywhere in what the agent sees, and the marker that says why.
    static func expectNoTitles(_ result: [String: Any]) throws {
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        #expect(!raw.contains("\"title\""), "a title field leaked: \(raw)")
        #expect(!raw.contains("Secret"), "a title leaked: \(raw)")
        #expect((result["structuredContent"] as? [String: Any])?["titles"] as? String == DesktopDiscovery.titlesHidden)
        #expect(try text(result).contains(DesktopDiscovery.titlesHidden))
        #expect(result["isError"] as? Bool == false)
    }
}

/// The injected desktop (see `DesktopDiscoveryTests`).
struct FakeDesktop: DesktopEnumerating {
    func runningApps() -> [DiscoveredApp] {
        [
            DiscoveredApp(pid: 100, name: "Terminal", bundleID: "com.apple.Terminal"),
            DiscoveredApp(pid: 102, name: "TextEdit", bundleID: "com.apple.TextEdit"),
            DiscoveredApp(pid: 103, name: "Safari", bundleID: "com.apple.Safari"),
            DiscoveredApp(pid: 104, name: "1Password", bundleID: "com.1password.1password"),
            DiscoveredApp(pid: 105, name: "cmux", bundleID: "com.cmuxterm.app"),
            DiscoveredApp(pid: 102, name: "TextEdit", bundleID: "com.apple.TextEdit"),
        ]
    }

    func windows() -> [DiscoveredWindow] {
        let pairs: [(UInt32, Int32)] = [(9000, 100), (9001, 102), (9003, 103), (9004, 104), (9005, 105), (9006, 103),
                                        (9010, 999)]
        return pairs.map { DiscoveredWindow(windowID: $0.0, pid: $0.1) }
    }
}
