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
