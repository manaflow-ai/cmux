@testable import CmuxNextAgentPane
import Foundation
import Testing

/// Read aloud in an agent chat, host side (user, 2026-10-29: "I clicked the speaker button to read
/// a message out loud and now I can't stop it"). The app owns the one voice: the page's speak and
/// stop decode, a second message stops the first, Stop Reading Aloud (palette, CLI, MCP) stops it
/// from anywhere, closing the chat that started it stops it, and a voice that ends on its own (or
/// one that was cut off and ends late) leaves the right state.
@MainActor @Suite struct AgentPaneReadAloudTests {
    /// A voice that records what it was told and ends only when the test says so.
    final class FakeVoice: AgentPaneReadAloudVoice {
        var said: [String] = []
        var languages: [String?] = []
        var stops = 0
        var finish: [@MainActor () -> Void] = []
        func speak(_ text: String, language: String?, finished: @escaping @MainActor () -> Void) {
            said.append(text)
            languages.append(language)
            finish.append(finished)
        }
        func stop() { stops += 1 }
    }

    final class Owner {}

    @Test func thePagesSpeakAndStopDecode() {
        let speak = AgentPaneRequest(body: ["method": "readAloud.speak", "params": ["id": "row-1", "text": "Hello", "lang": "ja"]])
        #expect(speak == .readAloud(.speak(id: "row-1", text: "Hello", language: "ja")))
        let plain = AgentPaneRequest(body: ["method": "readAloud.speak", "params": ["id": "row-1", "text": "Hello"]])
        #expect(plain == .readAloud(.speak(id: "row-1", text: "Hello", language: nil)))
        #expect(AgentPaneRequest(body: ["method": "readAloud.stop", "params": [:]]) == .readAloud(.stop))
        for bad: [String: Any] in [[:], ["id": "", "text": "x"], ["id": "a", "text": ""], ["id": "a"]] {
            #expect(AgentPaneRequest(body: ["method": "readAloud.speak", "params": bad]) == .unsupported("readAloud.speak"), "\(bad) decoded")
        }
        #expect(AgentPageOps.methods["readAloud.speak"] == "readAloud.speak", "the page host refuses the op")
        #expect(AgentPageOps.methods["readAloud.stop"] == "readAloud.stop", "the page host refuses the op")
    }

    @Test func stopEndsTheVoiceAtOnceFromAnywhere() {
        let voice = FakeVoice()
        let reader = AgentPaneReadAloud(voice: voice)
        let chat = Owner()
        var pushed: [String?] = []
        reader.onChange = { pushed.append(reader.reading(for: chat)) }
        reader.speak("A long answer", id: "a1", language: "en", owner: chat)
        #expect(voice.said == ["A long answer"] && voice.languages == ["en"])
        #expect(reader.reading(for: chat) == "a1")
        #expect(reader.reading(for: Owner()) == nil, "another chat's button said Stop")
        // Stop Reading Aloud (palette, CLI, MCP): no chat needed.
        #expect(reader.stop())
        #expect(voice.stops >= 1)
        #expect(reader.reading(for: chat) == nil)
        #expect(!reader.stop(), "nothing was reading, yet stop said it stopped something")
        #expect(pushed == ["a1", nil])
    }

    @Test func anotherMessageStopsTheFirstAndALateEndKeepsTheSecond() {
        let voice = FakeVoice()
        let reader = AgentPaneReadAloud(voice: voice)
        let chat = Owner()
        reader.speak("First", id: "a1", language: nil, owner: chat)
        let stopsBefore = voice.stops
        reader.speak("Second", id: "a2", language: nil, owner: chat)
        #expect(voice.stops > stopsBefore, "the first message kept talking under the second")
        #expect(reader.reading(for: chat) == "a2")
        // The first utterance reports its end after the second started: the second still reads.
        voice.finish[0]()
        #expect(reader.reading(for: chat) == "a2")
        // The second ends on its own: nothing reads.
        voice.finish[1]()
        #expect(reader.reading(for: chat) == nil)
    }

    @Test func closingTheChatThatReadsStopsIt() {
        let voice = FakeVoice()
        let reader = AgentPaneReadAloud(voice: voice)
        let chat = Owner(), other = Owner()
        reader.speak("Answer", id: "a1", language: nil, owner: chat)
        reader.stop(owner: other)
        #expect(reader.reading(for: chat) == "a1", "closing another chat stopped this one")
        let stopsBefore = voice.stops
        reader.stop(owner: chat)
        #expect(voice.stops > stopsBefore)
        #expect(reader.reading(for: chat) == nil)
    }

    @Test func theEventSaysWhichMessageThisChatReads() {
        let reader = AgentPaneReadAloud(voice: FakeVoice())
        let chat = Owner()
        #expect(reader.event(for: chat).value == .object(["id": .null]))
        reader.speak("Answer", id: "a1", language: nil, owner: chat)
        #expect(reader.event(for: chat).value == .object(["id": .string("a1")]))
        #expect(reader.event(for: Owner()).value == .object(["id": .null]))
        #expect(reader.event(for: chat).kind == "readAloud")
    }
}
