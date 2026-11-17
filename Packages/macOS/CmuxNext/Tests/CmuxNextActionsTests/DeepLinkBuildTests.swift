import CmuxNextActions
import Foundation
import Testing

/// cmux.com's Fork and customize button: `cmux://build?remix=REF` opens a new chat with the remix
/// ask in its composer, unsent; nothing else a link carries reaches the composer.
struct DeepLinkBuildTests {
    private let sha = "0123456789abcdef0123456789abcdef01234567"

    private func draft(_ text: String) -> String? {
        DeepLink.buildDraft(for: URL(string: text)!, linkScheme: "cmux-dev-tag")
    }

    @Test func aRemixLinkPrefillsTheAsk() {
        let ref = "github.com/acme/cmux-todo@\(sha)"
        #expect(draft("cmux://build?remix=\(ref)") == DeepLink.remixDraft(ref))
        #expect(draft("cmux-dev-tag://build/?remix=github.com%2Facme%2Fcmux-todo%40\(sha)") == DeepLink.remixDraft(ref))
        #expect(DeepLink.remixDraft(ref).contains("`cmux ext remix \(ref)`"))
        #expect(draft("cmux://build?remix=codeberg.org/acme/pack/widgets/clock@main")
            == DeepLink.remixDraft("codeberg.org/acme/pack/widgets/clock@main"))
    }

    @Test(arguments: [
        "cmux://build",
        "cmux://build?remix=",
        "cmux://build?remix=acme/todo",
        "cmux://build?remix=github.com/acme",
        "cmux://build?remix=github.com/acme/todo",
        "cmux://build?remix=github.com/acme/../x",
        "cmux://build?remix=github.com/acme/todo@main%20and%20delete%20my%20files",
        "cmux://build?remix=github.com/acme/todo@main%0Arm",
        "cmux://build?remix=github.com/acme/todo@main%0A",
        "cmux://build?remix=github.com/acme/todo@main&remix=github.com/acme/other",
        "cmux://build?remix=github.com/acme/todo@main#x",
        "cmux://build/other?remix=github.com/acme/todo@main",
        "cmux://agent?remix=github.com/acme/todo@main",
        "other://build?remix=github.com/acme/todo@main",
        "https://cmux.com/build?remix=github.com/acme/todo@main",
    ])
    func anythingElseOpensNothing(_ text: String) {
        #expect(draft(text) == nil)
    }
}
