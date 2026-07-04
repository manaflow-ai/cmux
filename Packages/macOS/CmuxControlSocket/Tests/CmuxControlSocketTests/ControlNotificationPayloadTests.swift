import Testing
@testable import CmuxControlSocket

@Suite("ControlNotificationPayload")
struct ControlNotificationPayloadTests {
    @Test("valid fourth agent meta is stripped from displayed body")
    func validAgentMetaIsStripped() throws {
        let payload = ControlNotificationPayload.parse("Claude|Completed|Hi.|c=turn-complete;p=0")

        #expect(payload.title == "Claude")
        #expect(payload.subtitle == "Completed")
        #expect(payload.body == "Hi.")
        let meta = try #require(payload.agentMeta)
        #expect(meta.category == .turnComplete)
        #expect(meta.pending == false)
    }

    @Test("valid agent meta accepts surrounding whitespace")
    func validAgentMetaAcceptsSurroundingWhitespace() throws {
        let payload = ControlNotificationPayload.parse(" Claude | Completed | Hi. | c=needs-permission;p=1 \n")

        #expect(payload.title == "Claude")
        #expect(payload.subtitle == "Completed")
        #expect(payload.body == "Hi.")
        let meta = try #require(payload.agentMeta)
        #expect(meta.category == .needsPermission)
        #expect(meta.pending == true)
    }

    @Test("invalid c-prefixed fourth segment folds back into body")
    func invalidAgentMetaFoldsBackIntoBody() {
        let payload = ControlNotificationPayload.parse("Claude|Completed|Hi.|c=turn-complete;p=2")

        #expect(payload.title == "Claude")
        #expect(payload.subtitle == "Completed")
        #expect(payload.body == "Hi.|c=turn-complete;p=2")
        #expect(payload.agentMeta == nil)
    }

    @Test("non-meta fourth segment folds back into body")
    func nonMetaFourthSegmentFoldsBackIntoBody() {
        let payload = ControlNotificationPayload.parse("Claude|Completed|Hi.|legacy tail")

        #expect(payload.title == "Claude")
        #expect(payload.subtitle == "Completed")
        #expect(payload.body == "Hi.|legacy tail")
        #expect(payload.agentMeta == nil)
    }

    @Test("meta-looking three-part body is legacy body")
    func metaLookingThreePartBodyIsLegacyBody() {
        let payload = ControlNotificationPayload.parse("Claude|Completed|c=turn-complete;p=0")

        #expect(payload.title == "Claude")
        #expect(payload.subtitle == "Completed")
        #expect(payload.body == "c=turn-complete;p=0")
        #expect(payload.agentMeta == nil)
    }

    @Test("legacy extra pipes stay in body when fourth segment is not full meta")
    func legacyExtraPipesStayInBody() {
        let payload = ControlNotificationPayload.parse("Claude|Completed|Hi|there|again")

        #expect(payload.title == "Claude")
        #expect(payload.subtitle == "Completed")
        #expect(payload.body == "Hi|there|again")
        #expect(payload.agentMeta == nil)
    }

    @Test("two-field payload still maps second field to body")
    func twoFieldPayloadStillMapsSecondFieldToBody() {
        let payload = ControlNotificationPayload.parse("Claude|Body only")

        #expect(payload.title == "Claude")
        #expect(payload.subtitle == "")
        #expect(payload.body == "Body only")
        #expect(payload.agentMeta == nil)
    }
}
