import CmuxConversationGeometry
import CoreGraphics
import Testing

/// The DEBUG lab's scripted scroll (`CMUX_UITEST_CONVERSATION_AUTOSCROLL`):
/// a deterministic sequence of drags, flicks and holds, so a scroll trace
/// can be recorded the same way before and after a change.
@Suite struct ConversationAutoScrollScriptTests {
    @Test func parsesEachStepKind() throws {
        let script = try #require(ConversationAutoScrollScript(parsing: "hold:1.5, drag:300:0.8, flick:-2500"))
        #expect(script.steps == [
            .hold(seconds: 1.5),
            .drag(points: 300, seconds: 0.8),
            .flick(velocity: -2500),
        ])
    }

    @Test func repeatsTheWholeSequence() throws {
        let script = try #require(ConversationAutoScrollScript(parsing: "repeat:2,hold:1,flick:100"))
        #expect(script.steps == [.hold(seconds: 1), .flick(velocity: 100), .hold(seconds: 1), .flick(velocity: 100)])
    }

    @Test func rejectsMalformedSteps() {
        #expect(ConversationAutoScrollScript(parsing: "drag:300") == nil)
        #expect(ConversationAutoScrollScript(parsing: "spin:3") == nil)
        #expect(ConversationAutoScrollScript(parsing: "hold:-1") == nil)
        #expect(ConversationAutoScrollScript(parsing: "") == nil)
    }

    /// `default` names the standard sequence: slow drags, flicks up into
    /// history and back down, and idle holds at rest.
    @Test func defaultNamesTheStandardSequence() throws {
        let script = try #require(ConversationAutoScrollScript(parsing: "default"))
        #expect(script == ConversationAutoScrollScript.standard)
        #expect(script.steps.contains { if case .flick(let v) = $0 { return v > 0 } else { return false } })
        #expect(script.steps.contains { if case .flick(let v) = $0 { return v < 0 } else { return false } })
        #expect(script.steps.contains { if case .hold = $0 { return true } else { return false } })
    }

    /// A drag moves its distance, eased, and ends exactly on it.
    @Test func dragEasesToItsDistance() {
        let step = ConversationAutoScrollScript.Step.drag(points: 300, seconds: 1)
        #expect(step.progress(at: 0).distance == 0)
        #expect(abs(step.progress(at: 0.5).distance - 150) < 0.001)
        #expect(step.progress(at: 1).distance == 300)
        #expect(step.progress(at: 1).finished)
        #expect(!step.progress(at: 0.99).finished)
    }

    /// A flick decelerates as UIScrollView's normal rate does (0.998 per
    /// millisecond): it travels v / (1000 ln(1/0.998)) points in all.
    @Test func flickDeceleratesLikeAScrollView() {
        let step = ConversationAutoScrollScript.Step.flick(velocity: 2000)
        let total = 2000 / (1000 * log(1 / 0.998))
        let late = step.progress(at: 10)
        #expect(late.finished)
        #expect(abs(late.distance - total) < 1)
        let early = step.progress(at: 0.1)
        #expect(!early.finished)
        #expect(early.distance > 0 && early.distance < total)
        #expect(step.progress(at: 0.2).distance > early.distance)
    }

    @Test func holdsDoNotMove() {
        let step = ConversationAutoScrollScript.Step.hold(seconds: 2)
        #expect(step.progress(at: 1) == .init(distance: 0, finished: false))
        #expect(step.progress(at: 2).finished)
    }
}
