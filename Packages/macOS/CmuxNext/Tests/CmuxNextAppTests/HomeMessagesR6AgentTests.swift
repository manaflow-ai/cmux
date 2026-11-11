import CmuxHomeCore
import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import Testing

/// Review round 6 of cmux#37736: the Messages page's Stop, Stop all agents, Continue and Restart
/// reach the conversation's own Chief (``HomeMessagesChiefTurn``), as the native compose button
/// and the stop-all toast did (HomeChiefTurnActions, HomeHostView+StopAll), and only on the
/// person's own click or key.
@MainActor @Suite
struct HomeMessagesR6AgentTests {
    @MainActor final class FakeChief: HomeMessagesChiefControl {
        var calls: [String] = []
        var stopAnswer: Result<Bool, HomeMessagesChiefRefusal> = .success(true)
        var restartRefusal: HomeMessagesChiefRefusal?

        func stopTurn() async -> Result<Bool, HomeMessagesChiefRefusal> {
            calls.append("stop")
            return stopAnswer
        }

        func stopAllAgents() async -> Result<HomeChiefStopAllAnswer, HomeMessagesChiefRefusal> {
            calls.append("stopAll")
            return .success(HomeChiefStopAllAnswer(stopped: true, subagents: ["a1", "a2"], errors: ["a3: busy"], note: "a4 is still starting"))
        }

        func continueStoppedTurn() async -> Result<(continued: Bool, reason: String?), HomeMessagesChiefRefusal> {
            calls.append("continue")
            return .success((continued: false, reason: "busy"))
        }

        func restartAgents(_ names: [String]) async -> HomeMessagesChiefRefusal? {
            calls.append("restart:" + names.joined(separator: ","))
            return restartRefusal
        }

        var startRefusal: HomeMessagesChiefRefusal?
        func startQueuedAgent(_ name: String) async -> HomeMessagesChiefRefusal? {
            calls.append("start:" + name)
            return startRefusal
        }

        var skills: Result<[HomeChiefSlashSkill]?, HomeMessagesChiefRefusal> = .success([])
        func slashSkills() async -> Result<[HomeChiefSlashSkill]?, HomeMessagesChiefRefusal> {
            calls.append("skills")
            return skills
        }
    }

    private func turn(_ chief: FakeChief?, asked: ((ConversationID) -> Void)? = nil) -> HomeMessagesChiefTurn {
        HomeMessagesChiefTurn { id in
            asked?(id)
            return chief
        }
    }

    private let conversation: [String: JSONValue] = ["conversation": .string("conv_chief")]

    /// A queued agent's pill: Start now asks the conversation's Chief to start it past its cap
    /// (`chief.stop {start}`, as the native pill card did); a refusal comes back in its words.
    @Test func startNowAsksTheChiefToStartTheQueuedAgent() async throws {
        let chief = FakeChief()
        let fields = conversation.merging(["agent": .string("a2")]) { $1 }
        #expect(try await turn(chief).call("chief.startAgent", fields, userGesture: true) == .object(["started": .bool(true)]))
        #expect(chief.calls == ["start:a2"])
        chief.startRefusal = HomeMessagesChiefRefusal("a2 is not waiting")
        do {
            _ = try await turn(chief).call("chief.startAgent", fields, userGesture: true)
            Issue.record("a refused start must throw")
        } catch let error as PageError {
            #expect(error.code == HomeMessagesChiefTurn.refusedCode)
            #expect(error.message == "a2 is not waiting")
        }
        await #expect(throws: PageError.self) { try await turn(chief).call("chief.startAgent", conversation, userGesture: true) }
        await #expect(throws: PageError.self) { try await turn(chief).call("chief.startAgent", fields, userGesture: false) }
    }

    /// `/` in a Chief's message box (the user, 2026-11-09): the page asks the conversation's Chief
    /// for its skills (`chief.engine.get` offered.skills) as the person types, with no click, and a
    /// Chief that cannot answer says why.
    @Test func skillsListTheConversationsChiefsSkillsWithoutAClick() async throws {
        let chief = FakeChief()
        chief.skills = .success([HomeChiefSlashSkill(name: "triage", description: "Sort the inbox", source: "chief")])
        let answer = try await turn(chief).call("chief.skills", conversation, userGesture: false)
        #expect(answer == .object([
            "skills": .array([.object([
                "name": .string("triage"), "description": .string("Sort the inbox"), "source": .string("chief"),
            ])]),
            "listed": .bool(true),
        ]))
        #expect(chief.calls == ["skills"])
        // A hosted Chief lists none at all: the page shows no list, not a failure.
        chief.skills = .success(nil)
        #expect(try await turn(chief).call("chief.skills", conversation, userGesture: false)
            == .object(["skills": .array([]), "listed": .bool(false)]))
        chief.skills = .failure(HomeMessagesChiefRefusal("the Chief is not running"))
        do {
            _ = try await turn(chief).call("chief.skills", conversation, userGesture: false)
            Issue.record("a Chief that cannot answer must throw")
        } catch let error as PageError {
            #expect(error.code == HomeMessagesChiefTurn.refusedCode)
            #expect(error.message == "the Chief is not running")
        }
        // Only the read goes without a click: the stop still needs one.
        await #expect(throws: PageError.self) { try await turn(chief).call("chief.stop", conversation, userGesture: false) }
    }

    @Test func stopReachesTheConversationsChief() async throws {
        let chief = FakeChief()
        var asked: [String] = []
        let answer = try await turn(chief, asked: { asked.append($0.rawValue) }).call("chief.stop", conversation, userGesture: true)
        #expect(answer == .object(["stopped": .bool(true)]))
        #expect(chief.calls == ["stop"])
        #expect(asked == ["conv_chief"], "the Chief of the page's conversation, not the front window's")
    }

    @Test func stopAllAnswersWhatStoppedForTheToast() async throws {
        let answer = try await turn(FakeChief()).call("chief.stopAll", conversation, userGesture: true)
        #expect(answer == .object([
            "stopped": .bool(true), "subagents": .array([.string("a1"), .string("a2")]),
            "errors": .array([.string("a3: busy")]), "note": .string("a4 is still starting"),
        ]))
    }

    @Test func continueAndRestartGoToTheBrain() async throws {
        let chief = FakeChief()
        let control = turn(chief)
        let went = try await control.call("chief.continue", conversation, userGesture: true)
        #expect(went == .object(["continued": .bool(false), "reason": .string("busy")]))
        var fields = conversation
        fields["names"] = .array([.string("a1"), .string("a2")])
        let restarted = try await control.call("chief.restart", fields, userGesture: true)
        #expect(restarted == .object(["restarted": .bool(true)]))
        #expect(chief.calls == ["continue", "restart:a1,a2"])
    }

    @Test func aScriptedCallRunsNothing() async {
        let chief = FakeChief()
        await #expect(throws: PageError.self) { try await turn(chief).call("chief.stop", conversation, userGesture: false) }
        #expect(chief.calls.isEmpty)
    }

    @Test func aRefusalCarriesItsWords() async {
        let chief = FakeChief()
        chief.stopAnswer = .failure(HomeMessagesChiefRefusal("The Chief could not be reached"))
        do {
            _ = try await turn(chief).call("chief.stop", conversation, userGesture: true)
            Issue.record("a refused stop must throw")
        } catch let error as PageError {
            #expect(error.code == HomeMessagesChiefTurn.refusedCode)
            #expect(error.message == "The Chief could not be reached")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func otherOpsAreNotTaken() async throws {
        #expect(try await turn(FakeChief()).call("chief.create", ["name": .string("x")], userGesture: true) == nil)
    }
}
