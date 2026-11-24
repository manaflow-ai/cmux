import CmuxNextActions
import Foundation
import Testing

/// App install links: `cmux://apps/install?repo=github.com/OWNER/REPO[/PATH]` with an optional
/// `&commit=<sha>` (else `&ref=`) runs `app.install` with the git reference, whose consent card
/// always shows. Anything else is not an install link.
struct DeepLinkAppInstallTests {
    private let scheme = "cmux-dev-mytag"
    private static let sha = "0123456789abcdef0123456789abcdef01234567"

    private func app(_ text: String) -> String? {
        let action = DeepLink.appInstallAction(for: URL(string: text)!, linkScheme: scheme)
        if let action { #expect(action.id == "app.install") }
        return action?.arguments["app"]?.stringValue
    }

    @Test func aRepoAloneInstallsItsDefaultBranch() {
        #expect(app("cmux://apps/install?repo=github.com/o/r") == "github.com/o/r")
        #expect(app("\(scheme)://apps/install?repo=github.com/o/r/apps/x") == "github.com/o/r/apps/x")
    }

    @Test func aCommitPinsTheReferenceAndWinsOverARef() {
        #expect(app("cmux://apps/install?repo=github.com/o/r&commit=\(Self.sha)") == "github.com/o/r@\(Self.sha)")
        #expect(app("cmux://apps/install?repo=github.com/o/r&commit=\(Self.sha.uppercased())&ref=main") == "github.com/o/r@\(Self.sha)")
    }

    @Test func aRefIsUsedWithNoCommitAndAShortCommitIsReadAsARef() {
        #expect(app("cmux://apps/install?repo=github.com/o/r&ref=v1.2.0") == "github.com/o/r@v1.2.0")
        #expect(app("cmux://apps/install?repo=github.com/o/r&commit=abc1234") == "github.com/o/r@abc1234")
        #expect(app("cmux://apps/install?repo=github.com/o/r&commit=&ref=main") == "github.com/o/r@main")
    }

    @Test(arguments: [
        "cmux://apps/install",                                         // no repo
        "cmux://apps/install?repo=",                                   // empty repo
        "cmux://apps/install?repo=github.com/o/r&repo=github.com/o/s", // repeated
        "cmux://apps/install?repo=github.com/o/r&ref=a&ref=b",         // repeated ref
        "cmux://apps/install?repo=github.com/o%20r",                   // whitespace
        "cmux://apps/install?repo=github.com/o/r&ref=ma%0Ain",         // newline in the ref
        "cmux://apps/install?repo=github.com/o/r@v1&ref=v2",           // two versions
        "cmux://apps/uninstall?repo=github.com/o/r",                   // another path
        "cmux://settings/install?repo=github.com/o/r",                 // another host
        "https://apps/install?repo=github.com/o/r",                    // another scheme
        "cmux-dev-other://apps/install?repo=github.com/o/r",           // another build's scheme
        "cmux://apps/install?repo=github.com/o/r#x",                   // a fragment
    ])
    func aMalformedInstallLinkIsNotOne(_ text: String) {
        #expect(DeepLink.appInstallAction(for: URL(string: text)!, linkScheme: scheme) == nil)
    }

    @Test func aRepoLongerThan512CharactersIsRefused() {
        let long = "github.com/o/" + String(repeating: "r", count: 500)
        #expect(app("cmux://apps/install?repo=\(long)") == nil)
        let fits = "github.com/o/" + String(repeating: "r", count: 499)
        #expect(app("cmux://apps/install?repo=\(fits)") == fits)
    }
}
