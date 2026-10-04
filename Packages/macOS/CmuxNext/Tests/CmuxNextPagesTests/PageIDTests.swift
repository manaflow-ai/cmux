@testable import CmuxNextPages
import Foundation
import Testing

/// First-party page ids (coordinator rule, P8 review): a manifest-declared page can never claim a
/// first-party id or the reserved `cmux.` namespace, nor first-party ops.
@Suite struct PageIDTests {
    @Test func everyShippedPageIsInTheFirstPartyTable() {
        #expect(PageID.isFirstParty(PageDescriptor.history.id))
        for id in ["cmux.history", "cmux.apps", "cmux.settings", "cmux.cloud", "cmux.agent", "cmux.keybindings"] {
            #expect(PageID.firstParty.contains(id))
        }
    }

    @Test func onlyTableIDsAreFirstPartyButTheWholeNamespaceIsReserved() {
        #expect(PageID.isFirstParty("cmux.agent"))
        #expect(!PageID.isFirstParty("cmux.agentx"))
        #expect(PageID.isReserved("cmux.agentx"))
        #expect(!PageID.isReserved("com.acme.diff"))
    }

    @Test func aManifestPageWithAFirstPartyIDIsRefused() {
        for id in ["cmux.agent", "CMUX.Agent", "cmux.settings", "cmux.agentx", "cmux"] {
            #expect(throws: PageID.Refusal.reservedID(id)) {
                try PageDescriptor.appPage(id: id, resource: "page", namespaces: [])
            }
        }
    }

    @Test func aManifestPageCannotClaimFirstPartyOrForeignOps() {
        #expect(throws: PageID.Refusal.reservedNamespace("cmux.agent.")) {
            try PageDescriptor.appPage(id: "com.acme.diff", resource: "page", namespaces: ["cmux.agent."])
        }
        #expect(throws: PageID.Refusal.reservedNamespace("com.other.")) {
            try PageDescriptor.appPage(id: "com.acme.diff", resource: "page", namespaces: ["com.other."])
        }
    }

    @Test func aWellFormedAppPageIsItsOwnOriginWithNoNativeAccess() throws {
        let page = try PageDescriptor.appPage(id: "com.acme.diff", resource: "diff", namespaces: ["com.acme.diff."])
        #expect(page.origin == "cmux-page://com.acme.diff")
        #expect(page.nativeOps.isEmpty && page.actions.isEmpty)
        #expect(!page.admits("cmux.app.action.run"))
        #expect(page.admits("com.acme.diff.files.list"))
    }

    @Test func idsAURLHostCannotCarryAreRefused() {
        for id in ["acme", "com..acme", "com.acme/../x", "com.acme_diff", ".com.acme"] {
            #expect(throws: PageID.Refusal.invalidID(id)) {
                try PageDescriptor.appPage(id: id, resource: "page", namespaces: [])
            }
        }
    }

    @Test func aFirstPartyPageIsServedOnlyFromItsBundledRoot() throws {
        let bundled = try #require(PageSchemeHandler.bundledRoot(for: .history))
        #expect(PageWebView.mayServe(.history, from: bundled))
        #expect(!PageWebView.mayServe(.history, from: URL(fileURLWithPath: "/tmp/evil-history")))
        let reservedNew = PageDescriptor(id: "cmux.agentx", resource: "x", namespaces: [])
        #expect(!PageWebView.mayServe(reservedNew, from: URL(fileURLWithPath: "/tmp/x")))
        let app = try PageDescriptor.appPage(id: "com.acme.diff", resource: "diff", namespaces: [])
        #expect(PageWebView.mayServe(app, from: URL(fileURLWithPath: "/tmp/acme")))
    }
}
