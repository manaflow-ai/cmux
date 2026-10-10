import CmuxAgentQuestion
import Foundation
import Testing

/// The answer round trip per harness: the reply a card sends must be the
/// exact `_acpmux/permission_respond` params the harness adapter reads.
@Suite struct AgentQuestionReplyTests {
    private func json(_ value: AgentQuestionJSON) throws -> String {
        String(decoding: try value.data(), as: UTF8.self)
    }

    @Test func claudeSingleSelectAnswersByQuestionText() throws {
        let question = try AgentQuestionFixture(name: "pending-single").question
        let reply = try question.reply(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["Passkeys"])]))
        #expect(try json(reply.params) == #"{"answers":{"Which auth method should the API use?":"Passkeys"},"optionId":"allow_once","permissionId":"perm_toolu_single","sessionId":"sess_claude_1"}"#)
    }

    @Test func claudeMultiSelectJoinsLabelsInOptionOrderThenOther() throws {
        let question = try AgentQuestionFixture(name: "pending-multi").question
        let reply = try question.reply(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["Web", "macOS"], other: "  visionOS ")]))
        #expect(reply.answers == ["Which platforms should the first release support?": "macOS, Web, visionOS"])
    }

    @Test func claudeOtherTextAnswersAlone() throws {
        let question = try AgentQuestionFixture(name: "pending-single").question
        let reply = try question.reply(AgentQuestionAnswer(selections: ["q0": .init(other: "Mutual TLS")]))
        #expect(reply.answers == ["Which auth method should the API use?": "Mutual TLS"])
    }

    @Test func codexAnswersByIdWithArrays() throws {
        let question = try AgentQuestionFixture(name: "codex-user-input").question
        let reply = try question.reply(AgentQuestionAnswer(selections: [
            "db_engine": .init(optionIDs: ["SQLite"]),
            "service_name": .init(other: "ledger"),
        ]))
        #expect(reply.optionId == "allow_once")
        #expect(reply.answers == ["db_engine": ["answers": ["SQLite"]], "service_name": ["answers": ["ledger"]]])
    }

    @Test func acpInteractiveAnswersWithTheChosenPermissionOption() throws {
        let question = try AgentQuestionFixture(name: "acp-interactive").question
        let reply = try question.reply(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["dry_run"])]))
        #expect(reply.optionId == "dry_run")
        #expect(reply.answers == nil)
    }

    @Test func chiefAnswersLikeClaude() throws {
        let question = try AgentQuestionFixture(name: "chief-asks").question
        let reply = try question.reply(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["wait"])]))
        #expect(reply.session == "sess_mux")
        #expect(reply.answers == ["Two agents finished. Merge both branches into feat-cmux-next now?": "Wait"])
    }

    @Test func declineUsesTheRejectOptionNeverAnAllow() throws {
        for name in AgentQuestionFixture.names {
            let question = try AgentQuestionFixture(name: name).question
            let decline = try #require(question.declineReply())
            #expect(decline.optionId == question.source.rejectOption, "\(name)")
            #expect(decline.optionId != question.source.answerOption, "\(name)")
            #expect(decline.answers == nil)
        }
    }

    @Test func invalidAnswersAreRefused() throws {
        let single = try AgentQuestionFixture(name: "pending-single").question
        #expect(throws: AgentQuestionAnswer.Problem.unanswered(item: "q0")) { try single.reply(AgentQuestionAnswer(selections: [:])) }
        #expect(throws: AgentQuestionAnswer.Problem.tooManyChoices(item: "q0")) {
            try single.reply(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["OAuth 2.0", "Passkeys"])]))
        }
        #expect(throws: AgentQuestionAnswer.Problem.unknownOption(item: "q0", option: "Kerberos")) {
            try single.reply(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["Kerberos"])]))
        }
        let acp = try AgentQuestionFixture(name: "acp-interactive").question
        #expect(throws: AgentQuestionAnswer.Problem.otherNotAllowed(item: "q0")) {
            try acp.reply(AgentQuestionAnswer(selections: ["q0": .init(other: "maybe")]))
        }
        let answered = try AgentQuestionFixture(name: "answered-collapsed").question
        #expect(throws: AgentQuestionAnswer.Problem.notPending) {
            try answered.reply(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["Passkeys"])]))
        }
    }

    @Test func summaryLinesUseHeaders() throws {
        let question = try AgentQuestionFixture(name: "pending-multi").question
        #expect(question.summaryLines(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["iOS", "macOS"])])) == ["Platforms: macOS, iOS"])
    }
}
