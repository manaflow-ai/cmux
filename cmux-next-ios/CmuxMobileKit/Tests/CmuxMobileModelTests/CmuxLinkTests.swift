// The grammar is Rust's (cmux_link.rs, which runs these cases too); it links on iOS only.
#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileModel

/// The phone reads the links the Mac writes (`CmuxNextActions/DeepLink`) and the
/// https forms cmux.com and the Cloud service hand out (verify/deep-links.md).
@Suite struct CmuxLinkTests {
    let ws = "ws_0123456789abcdef0123456789abcdef"
    let pane = "pane_0123456789abcdef0123456789abcdef"
    let tab = "tab_0123456789abcdef0123456789abcdef"

    func link(_ text: String) -> CmuxLink? { URL(string: text).flatMap(CmuxLink.init(url:)) }

    @Test func readsEveryKindTheMacWrites() {
        #expect(link("cmux://workspace/\(ws)")?.target == .workspace(ws))
        #expect(link("cmux://pane/\(pane)")?.target == .pane(pane))
        #expect(link("cmux://tab/\(tab)?machine=machine_0123456789abcdef0123456789abcdef")?.target == .tab(tab))
        #expect(link("cmux://session/s-1#turn-t9")?.target == .session("s-1", turn: "t9"))
        #expect(link("cmux://chief/0a1b2c3d/session/s-1")?.target == .chiefSession(home: "0a1b2c3d", session: "s-1"))
        #expect(link("cmux://group/grp_abcdefghij0123456789/workspace/\(ws)")?.target == .group("grp_abcdefghij0123456789", workspace: ws))
        #expect(link("cmux://conversation/c-release/message/c-release-m4")?.target == .conversation("c-release", message: "c-release-m4"))
    }

    /// A Mac screen link (`acpmux share-host link`): one shape, native and web; View Only unless `control=1`.
    @Test func readsAMacScreenLink() {
        let device = "0f8e2c1a-3b4d-4e5f-8a9b-0c1d2e3f4a5b"
        let expected = CmuxLink.Target.macScreen(.init(device: device, display: "69734272"))
        for scheme in ["cmux", "cmux-nightly", "cmux-dev-my-tag"] {
            #expect(link("\(scheme)://mac-screen?device=\(device)&display=69734272")?.target == expected, "\(scheme)")
        }
        for host in ["cmux.com", "www.cmux.com"] {
            #expect(link("https://\(host)/deeplink/screen?device=\(device)&display=69734272")?.target == expected, "\(host)")
        }
        #expect(link("https://cmux.com/en/deeplink/screen?device=\(device)")?.target == .macScreen(.init(device: device)))
        // Upper case ids read as the hub's lowercase one; control and the label ride along.
        #expect(link("cmux://mac-screen?device=\(device.uppercased())&control=1&name=ui%20run%2042")?.target
            == .macScreen(.init(device: device, control: true, name: "ui run 42")))
        #expect(link("cmux://mac-screen?device=\(device)&control=0")?.target == .macScreen(.init(device: device)))
        #expect(link("cmux://mac-screen?device=\(device)")?.kind == "mac-screen")
        for text in [
            "cmux://mac-screen", "cmux://mac-screen?device=not-a-uuid", "cmux://mac-screen?display=1",
            "cmux://mac-screen?device=\(device)&display=-1", "cmux://mac-screen?device=\(device)&display=4294967296",
            "cmux://mac-screen?device=\(device)&display=1&display=2", "cmux://mac-screen/x?device=\(device)",
            "cmux://mac-screen?device=\(device)#x", "https://example.com/deeplink/screen?device=\(device)",
            "cmux-next://mac-screen?device=\(device)",
        ] {
            #expect(link(text) == nil, "\(text)")
        }
    }

    @Test func readsEveryMacBuildsScheme() {
        for scheme in ["cmux", "CMUX", "cmux-nightly", "cmux-rc", "cmux-dev", "cmux-dev-my-tag"] {
            #expect(link("\(scheme)://tab/\(tab)")?.target == .tab(tab), "\(scheme)")
        }
    }

    @Test func refusesWhatIsNotALink() {
        for text in [
            "cmux://auth-callback?code=x", "cmux-next://pair?mac=m&t=secret", "other://tab/\(tab)",
            "cmux://tab/tab_ABC", "cmux://tab/\(tab)/extra", "cmux://workspace/\(UUID().uuidString)",
            "cmux://tab/\(tab)#x", "cmux://user:pw@tab/\(tab)", "https://example.com/link/tab/\(tab)",
            "https://cmux.com/terms-of-service", "https://cmux.com/link/tab/nope",
        ] {
            #expect(link(text) == nil, "\(text)")
        }
    }

    @Test func readsTheHttpsForms() {
        #expect(link("https://cmux.com/link/tab/\(tab)")?.target == .tab(tab))
        #expect(link("https://www.cmux.com/en/link/workspace/\(ws)")?.target == .workspace(ws))
        #expect(link("https://cloud-api.cmux.dev/g/grp_abcdefghij0123456789")?.target == .group("grp_abcdefghij0123456789", workspace: nil))
        #expect(link("https://cmux.com/ja/deeplink/agent?harness=codex&session=s1")?.target == .agent(harness: "codex", session: "s1"))
    }

    /// schemas/deeplinks/agent-link.json is the one contract the Mac, the CLI
    /// and cmux.com write agent links by: each of its vectors reads the same here.
    @Test func followsTheSharedAgentLinkSchema() throws {
        let schema = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schemas/deeplinks/agent-link.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: schema)) as? [String: Any]
        let vectors = try #require(object?["vectors"] as? [[String: Any]])
        #expect(vectors.count > 10)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let fields = vector["fields"] as? [String: String]
            var forms: [String] = []
            if let web = vector["web"] as? String { forms.append("https://cmux.com/deeplink/agent?\(web)") }
            if let native = vector["link"] as? String, vector["web"] == nil { forms.append(native) }
            for form in forms {
                let parsed = link(form)
                guard let fields else {
                    #expect(parsed == nil, "\(name): \(form)")
                    continue
                }
                #expect(parsed?.target == .agent(harness: fields["harness"] ?? "", session: fields["session"] ?? ""), "\(name): \(form)")
                #expect(parsed?.message == fields["message"], "\(name): \(form)")
            }
        }
    }
}
#endif
