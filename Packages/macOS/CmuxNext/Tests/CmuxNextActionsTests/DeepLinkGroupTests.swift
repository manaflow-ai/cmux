import CmuxNextActions
import Foundation
import Testing

/// Cloud group links (plans/cmux-next/cloud-groups-DESIGN.md slice 1): `cmux://group/<grp_id>`,
/// optionally `/workspace/<ws_id>`, and the https hand-off form `https://cloud-api.cmux.dev/g/<grp_id>`.
/// A group id is TeamDO's `grp_` + 20 lowercase letters or digits; anything else is not a link.
struct DeepLinkGroupTests {
    private static let group = "grp_f9a917b1721deb93e834"
    private static let workspace = "ws_44220fb62e6d67c82e50c9faf18eb4c3"

    private func parse(_ text: String) -> DeepLink? {
        DeepLink.parse(URL(string: text)!, scheme: "cmux")
    }

    @Test func aGroupLinkParsesAndFormatsBack() throws {
        let text = "cmux://group/\(Self.group)"
        let link = try #require(parse(text))
        #expect(link.target == .group(Self.group, workspace: nil))
        #expect(link.url(scheme: "cmux")?.absoluteString == text)
    }

    @Test func aGroupLinkMayNameOneOfItsWorkspaces() throws {
        let text = "cmux://group/\(Self.group)/workspace/\(Self.workspace)"
        let link = try #require(parse(text))
        #expect(link.target == .group(Self.group, workspace: Self.workspace))
        #expect(link.url(scheme: "cmux")?.absoluteString == text)
    }

    @Test(arguments: [
        "cmux://group/grp_F9A917B1721DEB93E834",            // uppercase
        "cmux://group/grp_f9a917b1721deb93e83",             // 19 characters
        "cmux://group/grp_f9a917b1721deb93e8345",           // 21 characters
        "cmux://group/ws_44220fb62e6d67c82e50c9faf18eb4c3", // another kind's id
        "cmux://group/grp_f9a917b1721deb93e834/workspace/grp_f9a917b1721deb93e834",
        "cmux://group/grp_f9a917b1721deb93e834/tab/tab_44220fb62e6d67c82e50c9faf18eb4c3",
        "cmux://group/grp_f9a917b1721deb93e834#turn-1",
        "cmux://group/grp_f9a917b1721deb93e834/workspace/ws_44220fb62e6d67c82e50c9faf18eb4c3/x"
    ])
    func aMalformedGroupLinkIsNotALink(_ text: String) {
        #expect(parse(text) == nil)
    }

    @Test func theWebFormOpensTheSameGroup() throws {
        let prod = try #require(DeepLink.parseGroupWeb(URL(string: "https://cloud-api.cmux.dev/g/\(Self.group)")!))
        #expect(prod.target == .group(Self.group, workspace: nil))
        let staging = try #require(DeepLink.parseGroupWeb(URL(string: "https://cloud-api-staging.cmux.dev/g/\(Self.group)/w/\(Self.workspace)")!))
        #expect(staging.target == .group(Self.group, workspace: Self.workspace))
        #expect(DeepLink.parseGroupWeb(URL(string: "https://cmux.com/g/\(Self.group)")!) != nil)
    }

    @Test(arguments: [
        "https://evil.example/g/grp_f9a917b1721deb93e834",
        "http://cloud-api.cmux.dev/g/grp_f9a917b1721deb93e834",
        "https://cloud-api.cmux.dev:8443/g/grp_f9a917b1721deb93e834",
        "https://cloud-api.cmux.dev/g/grp_f9a917b1721deb93e834?run=1",
        "https://cloud-api.cmux.dev/g/grp_nothex!",
        "https://cloud-api.cmux.dev/x/grp_f9a917b1721deb93e834"
    ])
    func otherWebURLsAreNotGroupLinks(_ text: String) {
        #expect(DeepLink.parseGroupWeb(URL(string: text)!) == nil)
    }
}
