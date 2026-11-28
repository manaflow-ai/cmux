import Foundation
import Testing
@testable import CmuxNextMobile

struct MobileHostSiteDataTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["off", "on", "timeout"])
    func supervisorOnlyReadsAfterOptIn(scenario: String) async throws {
        let enabled = scenario != "off"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("site-data-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("host")
        let reply = directory.appendingPathComponent("reply")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"type":"site_data_handoff"'*)
              echo '{"type":"need_site_data","request":73,"surface":42,"site":"example.com","url":"https://example.com/"}' ;;
            *'"type":"site_data"'*|*'"type":"site_data_failed"'*)
              printf '%s\\n' "$line" > "\(reply.path)"
              echo '{"type":"online","device_id":"d","team_id":"t"}' ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let supervisor = MobileHostSupervisor()
        if enabled { await supervisor.setSiteDataHandoff(enabled: true) }
        await supervisor.start(.init(launch: MobileHostTests.launch(executable: script), accessToken: { _ in "test" },
            acpmux: { nil }, log: nil, siteData: { request in
                #expect(enabled)
                #expect(request.surface == 42)
                if scenario == "timeout" {
                    // The adapter can stall; the supervisor must refuse within its own deadline.
                    try await Task.sleep(for: .seconds(30))
                }
                return MobileHostSiteData(profileID: "personal", agentsProfile: false, incognito: false, cookies: [], localStorage: [])
            }))
        for await state in supervisor.states where state.phase == .online { break }
        await supervisor.stop()
        let wire = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reply)) as? [String: Any])
        #expect(wire["type"] as? String == (scenario == "on" ? "site_data" : "site_data_failed"))
        #expect(wire["request"] as? Int == 73)
    }

    @Test func requestRequiresCompleteCorrelationAndTabIdentity() throws {
        let request = MobileHostSiteDataRequest(request: 17, surface: 42, site: "example.com", url: "https://example.com/a")
        #expect(MobileHostEvent(line: #"{"type":"need_site_data","request":17,"surface":42,"site":"example.com","url":"https://example.com/a"}"#)
            == .needSiteData(request))
        for field in ["request", "surface", "site", "url"] {
            var wire: [String: Any] = ["type": "need_site_data", "request": 17, "surface": 42, "site": "example.com", "url": "https://example.com/a"]
            wire.removeValue(forKey: field)
            let line = String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
            #expect(MobileHostEvent(line: line) == nil)
        }
        #expect(MobileHostEvent(line: #"{"type":"need_site_data","request":17,"surface":-1,"site":"example.com","url":"https://example.com/a"}"#) == nil)
    }

    @Test func snapshotMatchesRustWireAndPreservesCookieSemantics() throws {
        let cookie = MobileHostSiteData.Cookie(name: "auth", value: "secret-cookie", domain: ".example.com", path: "/a",
                                               expiresMS: 1_800_000_000_000, secure: true, httpOnly: true, sameSite: "strict")
        let session = MobileHostSiteData.Cookie(name: "session", value: "session-secret", domain: "example.com", path: "/",
                                                expiresMS: nil, secure: true, httpOnly: false, sameSite: nil)
        let storage = MobileHostSiteData.StorageArea(origin: "https://example.com", items: [["auth", "secret-storage"]])
        let data = MobileHostSiteData(profileID: "personal", agentsProfile: false, incognito: false, cookies: [cookie, session], localStorage: [storage])
        let line = try #require(MobileHostLaunch.siteDataLine(request: 17, data: data))
        #expect(line.last == 0x0a)
        let reply = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(reply["type"] as? String == "site_data")
        #expect(reply["request"] as? Int == 17)
        let snapshot = try #require(reply["data"] as? [String: Any])
        #expect(snapshot["profile_id"] as? String == "personal")
        #expect(snapshot["agents_profile"] as? Bool == false)
        #expect(snapshot["incognito"] as? Bool == false)
        let cookies = try #require(snapshot["cookies"] as? [[String: Any]])
        #expect(cookies[0]["value"] as? String == "secret-cookie")
        #expect(cookies[0]["expires_ms"] as? Int64 == 1_800_000_000_000)
        #expect(cookies[0]["http_only"] as? Bool == true)
        #expect(cookies[0]["same_site"] as? String == "strict")
        #expect(cookies[1]["expires_ms"] == nil)
        let areas = try #require(snapshot["local_storage"] as? [[String: Any]])
        #expect(areas[0]["items"] as? [[String]] == [["auth", "secret-storage"]])
        #expect(!String(describing: data).contains("secret"))
        #expect(!String(reflecting: cookie).contains("secret"))
        #expect(!String(reflecting: storage).contains("secret"))
        #expect(!String(reflecting: data).contains("secret"))
    }

    @Test func oversizedControlReplyIsRefused() {
        let storage = MobileHostSiteData.StorageArea(origin: "https://example.com", items: [["large", String(repeating: "x", count: 2 * 1024 * 1024)]])
        let data = MobileHostSiteData(profileID: "personal", agentsProfile: false, incognito: false, cookies: [], localStorage: [storage])
        #expect(MobileHostLaunch.siteDataLine(request: 1, data: data) == nil)
    }

    @Test func enablingAndRefusalUseTheHostProtocol() throws {
        for enabled in [false, true] {
            let line = MobileHostLaunch.siteDataHandoffLine(enabled: enabled)
            let wire = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
            #expect(wire["type"] as? String == "site_data_handoff")
            #expect(wire["enabled"] as? Bool == enabled)
        }
        let wire = try #require(JSONSerialization.jsonObject(with: MobileHostLaunch.siteDataFailedLine(request: 9)) as? [String: Any])
        #expect(wire["type"] as? String == "site_data_failed")
        #expect(wire["request"] as? Int == 9)
        #expect(wire["reason"] as? String == "site data unavailable")
    }
}
