import Foundation
import Testing
@testable import CmuxRemoteWorkspace

private let scheme = "cmux-test"
private let supported: Set<String> = [scheme]

@Suite("CmuxDeepLinkDispatchPlan")
struct CmuxDeepLinkDispatchPlanTests {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("invalid test URL: \(string)")
        }
        return url
    }

    private func sshPlan(_ strings: [String]) -> CmuxDeepLinkDispatchPlan<CmuxSSHURLRequest, CmuxSSHURLParseError> {
        CmuxDeepLinkDispatchPlan(parsing: strings.map(url)) { url in
            CmuxSSHURLRequest.parse(url, supportedSchemes: supported)
        }
    }

    @Test("no recognized link resolves to empty and no intents")
    func emptyResolution() {
        let plan = sshPlan(["https://example.com/page"])
        #expect(plan.intentCount == 0)
        #expect(plan.requests.isEmpty)
        #expect(plan.parseErrors.isEmpty)
        guard case .empty = plan.resolution else {
            Issue.record("expected .empty, got \(plan.resolution)")
            return
        }
    }

    @Test("a single accepted link resolves to single dispatch with no parse errors")
    func singleRequestResolution() {
        let plan = sshPlan(["\(scheme)://ssh?host=example.com"])
        #expect(plan.intentCount == 1)
        #expect(plan.requests.count == 1)
        guard case .single(let parseErrors, let request) = plan.resolution else {
            Issue.record("expected .single, got \(plan.resolution)")
            return
        }
        #expect(parseErrors.isEmpty)
        #expect(request != nil)
    }

    @Test("a single rejected link resolves to single with the parse error and no request")
    func singleParseErrorResolution() {
        // A scheme-matching ssh link with no destination is rejected.
        let plan = sshPlan(["\(scheme)://ssh/"])
        #expect(plan.intentCount == 1)
        #expect(plan.parseErrors.count == 1)
        guard case .single(let parseErrors, let request) = plan.resolution else {
            Issue.record("expected .single, got \(plan.resolution)")
            return
        }
        #expect(parseErrors.count == 1)
        #expect(request == nil)
    }

    @Test("more than one intent resolves to multipleLinks regardless of request/error mix")
    func multipleLinksResolution() {
        let plan = sshPlan([
            "\(scheme)://ssh?host=example.com",
            "\(scheme)://ssh?host=other.com",
        ])
        #expect(plan.intentCount == 2)
        guard case .multipleLinks = plan.resolution else {
            Issue.record("expected .multipleLinks, got \(plan.resolution)")
            return
        }
    }

    @Test("non-matching URLs are dropped and do not count as intents")
    func nonMatchingDropped() {
        let plan = sshPlan([
            "https://example.com/page",
            "\(scheme)://ssh?host=example.com",
            "mailto:someone@example.com",
        ])
        #expect(plan.intentCount == 1)
        #expect(plan.requests.count == 1)
        #expect(plan.parseErrors.isEmpty)
    }
}
