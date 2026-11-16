import CMUXAuthCore
import Foundation
import Testing

/// The three states a build's cloud data space can be in, and what a client does with each: a tagged dev build's
/// header, nothing for nightly, and a refusal (never nightly's space) for a dev build with no usable tag.
@Suite("CMUXBuildSpaceState")
struct CMUXBuildSpaceStateTests {
    static let url = URL(string: "https://cloud-api-staging.cmux.dev/v1/ops") ?? URL(fileURLWithPath: "/dev/null")

    @Test("A usable tag is the tag's space, in a dev build or any other", arguments: [true, false])
    func dev(devBuild: Bool) throws {
        let state = CMUXBuildSpaceState(devBuild: devBuild, devTag: "My_Tag 2")
        #expect(state == .dev(try #require(CMUXBuildSpace(devTag: "My_Tag 2"))))
        #expect(state.space?.headerValue == "dev:my-tag-2")
        #expect(state.refusal == nil)
    }

    @Test("A build that is no dev build and has no tag is nightly", arguments: [nil, "", "  ", "$(CMUX_DEV_TAG)"] as [String?])
    func nightly(devTag: String?) {
        let state = CMUXBuildSpaceState(devBuild: false, devTag: devTag)
        #expect(state == .nightly)
        #expect(state.space == nil)
        #expect(state.refusal == nil)
    }

    @Test("A dev build with no tag, an unexpanded one or one with no usable slug is misconfigured", arguments: [
        nil, "", "  ", "$(CMUX_MOBILE_TAG)", "---", "\u{E9}\u{E9}", String(repeating: "a", count: 65),
    ] as [String?])
    func misconfiguredDevBuild(devTag: String?) {
        let state = CMUXBuildSpaceState(devBuild: true, devTag: devTag)
        guard case .misconfiguredDev = state else {
            Issue.record("\(String(describing: devTag)) made \(state)")
            return
        }
        #expect(state.space == nil)
        #expect(state.refusal != nil)
    }

    @Test("A tag meant as a space of its own but unusable is misconfigured in any build", arguments: [
        "---", String(repeating: "a", count: 65),
    ])
    func unusableTag(devTag: String) {
        #expect(CMUXBuildSpaceState(devBuild: false, devTag: devTag).refusal != nil)
    }

    @Test("A dev build's requests carry its space; nightly's carry nothing")
    func apply() throws {
        let dev = CMUXBuildSpaceState(devBuild: true, devTag: "feat-x")
        var request = URLRequest(url: Self.url)
        try dev.apply(to: &request)
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:feat-x")
        #expect(try dev.headers() == ["X-Cmux-Build-Space": "dev:feat-x"])
        #expect(try dev.headerValue() == "dev:feat-x")
        var plain = URLRequest(url: Self.url)
        try CMUXBuildSpaceState.nightly.apply(to: &plain)
        #expect(plain.allHTTPHeaderFields?.isEmpty ?? true)
        #expect(try CMUXBuildSpaceState.nightly.headers().isEmpty)
        #expect(try CMUXBuildSpaceState.nightly.headerValue() == nil)
    }

    @Test("A misconfigured dev build's every use throws, and sets no header")
    func misconfiguredRefuses() {
        let state = CMUXBuildSpaceState(devBuild: true, devTag: nil)
        var request = URLRequest(url: Self.url)
        #expect(throws: CMUXBuildSpaceError.self) { try state.apply(to: &request) }
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Build-Space") == nil)
        #expect(throws: CMUXBuildSpaceError.self) { try state.check() }
        #expect(throws: CMUXBuildSpaceError.self) { _ = try state.headers() }
        #expect(throws: CMUXBuildSpaceError.self) { _ = try state.headerValue() }
    }

    @Test("The refusal says what is wrong and that the build makes no cloud calls")
    func refusalText() throws {
        let refusal = try #require(CMUXBuildSpaceState(devBuild: true, devTag: nil).refusal)
        let text = try #require(refusal.errorDescription)
        #expect(text.contains("no usable build space tag"))
        #expect(text.contains("it has no tag"))
        #expect(text.contains("nightly"))
        #expect(refusal.localizedDescription == text)
    }
}
