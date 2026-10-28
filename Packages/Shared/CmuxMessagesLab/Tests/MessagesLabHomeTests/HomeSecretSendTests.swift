import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A key pasted into Home chat never goes out by accident (cmux issue 26412): Return holds a
/// message that holds an API key or token, the host is asked to move it to the Credential Vault,
/// and what it moved becomes `[vault:NAME]` in the field, so the next Return sends the message
/// without the key. The real view over a real `HomeStore` on the mock owner.
@MainActor @Suite(.serialized) struct HomeSecretSendTests {
    static let key = "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz012345"

    @Test func shapesAreFoundAndOrdinaryTextIsNot() {
        let scan = HomeSecretScan()
        let found = scan.findings(in: "use \(Self.key) and ghp_0123456789abcdefghijABCDEFGHIJ0123 please, again \(Self.key)")
        #expect(found == [.init(value: Self.key, suggestedName: "OPENAI_API_KEY"),
                          .init(value: "ghp_0123456789abcdefghijABCDEFGHIJ0123", suggestedName: "GH_TOKEN")])
        #expect(scan.findings(in: "sk-ant-api03-abcdefghijklmnopqrstuvwxyz").first?.suggestedName == "ANTHROPIC_API_KEY")
        #expect(scan.findings(in: "AKIAIOSFODNN7EXAMPLE").first?.suggestedName == "AWS_ACCESS_KEY_ID")
        for plain in ["commit 3f2a9c1e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a39", "https://example.com/sk-learn-docs/page",
                      "ask-me-anything-about-the-plan-for-today", "the task-12345678901234567890 id", "short sk-123"] {
            #expect(scan.findings(in: plain).isEmpty, "\(plain)")
        }
    }

    @Test func aPastedKeyIsHeldMovedToTheVaultAndTheMessageNamesItInstead() async throws {
        let rig = try await HomeChatRig(history: 0)
        defer { rig.stop() }
        var asked: [[HomeSecretScan.Finding]] = []
        rig.view.secretHost = { findings in
            asked.append(findings)
            return findings.map { ($0.value, "WORK_OPENAI") }
        }
        let text = "\(HomeChatRig.tag) run the eval with \(Self.key)"
        let held = await rig.send(text)
        #expect(held?.hasPrefix("held") == true, "\(held ?? "sent")")
        await HomeChatRig.until { rig.view.controller.store?.state.ui.draft.text.contains("[vault:WORK_OPENAI]") == true }
        #expect(asked == [[.init(value: Self.key, suggestedName: "OPENAI_API_KEY")]])
        let draft = try #require(rig.view.controller.store?.state.ui.draft.text)
        #expect(draft == "\(HomeChatRig.tag) run the eval with [vault:WORK_OPENAI]")
        #expect(rig.storeItems().isEmpty, "nothing went out while it was held")
        #expect(rig.store.draft(for: HomeChatRig.conversation)?.contains(Self.key) != true, "the kept draft no longer holds the key")

        #expect(rig.view.projection.send() == nil)
        await HomeChatRig.until { !rig.storeItems().isEmpty }
        #expect(rig.storeItems() == ["\(HomeChatRig.tag) run the eval with [vault:WORK_OPENAI]"])
    }

    /// Review of https://github.com/manaflow-ai/cmux/issues/26412: a double Return sent the key
    /// before the vault sheet was answered. While the offer is open every Return is held; only after
    /// the person answered and moved nothing does a Return send the text as typed.
    @Test func aReturnSendsItAsTypedOnlyAfterThePersonAnsweredAndMovedNothing() async throws {
        let rig = try await HomeChatRig(history: 0)
        defer { rig.stop() }
        var asks = 0
        var answer: CheckedContinuation<Void, Never>?
        rig.view.secretHost = { _ in
            asks += 1
            await withCheckedContinuation { answer = $0 }
            return []
        }
        let text = "\(HomeChatRig.tag) this one is a test key \(Self.key)"
        #expect(await rig.send(text)?.hasPrefix("held") == true)
        await HomeChatRig.until { answer != nil }
        #expect(await rig.send(text)?.hasPrefix("held") == true, "a second Return while the sheet is open")
        #expect(await rig.send(text)?.hasPrefix("held") == true, "and a third")
        #expect(rig.storeItems().isEmpty)
        #expect(asks == 1, "one offer")

        answer?.resume()
        await HomeChatRig.until { !rig.view.projection.secretOfferOpen }
        #expect(await rig.send(text) == nil, "the person answered and chose to send it")
        #expect(rig.storeItems() == [text])
        #expect(asks == 1)
    }

    /// Review: no window to show the sheet on (or a vault failure) read as "moved nothing", and the
    /// next Return sent the key though the person never saw the offer. It stays held.
    @Test func aKeyStaysHeldWhenTheOfferCouldNotBeShown() async throws {
        let rig = try await HomeChatRig(history: 0)
        defer { rig.stop() }
        var asks = 0
        rig.view.secretHost = { _ in
            asks += 1
            return nil
        }
        let text = "\(HomeChatRig.tag) the key is \(Self.key)"
        #expect(await rig.send(text)?.hasPrefix("held") == true)
        await HomeChatRig.until { asks == 1 && !rig.view.projection.secretOfferOpen }
        #expect(await rig.send(text)?.hasPrefix("held") == true, "never sent as typed without an answer")
        await HomeChatRig.until { asks == 2 }
        #expect(rig.storeItems().isEmpty)
        #expect(asks == 2, "each Return offers again")
    }

    @Test func withoutAHostAMessageGoesAsTyped() async throws {
        let rig = try await HomeChatRig(history: 0)
        defer { rig.stop() }
        let text = "\(HomeChatRig.tag) \(Self.key)"
        #expect(await rig.send(text) == nil)
        #expect(rig.storeItems() == [text])
    }
}
