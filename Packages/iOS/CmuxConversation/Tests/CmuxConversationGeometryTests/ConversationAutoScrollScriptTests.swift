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

    /// A step names itself in script syntax (its signpost label), which
    /// parses back to the same step.
    @Test func stepsNameThemselvesInScriptSyntax() throws {
        let steps: [ConversationAutoScrollScript.Step] = [.hold(seconds: 2), .drag(points: -200, seconds: 0.5), .flick(velocity: 4500)]
        #expect(steps.map(\.scriptText) == ["hold:2.0", "drag:-200.0:0.5", "flick:4500.0"])
        for step in steps {
            let parsed = try #require(ConversationAutoScrollScript(parsing: step.scriptText))
            #expect(parsed.steps == [step])
        }
    }

    @Test func holdsDoNotMove() {
        let step = ConversationAutoScrollScript.Step.hold(seconds: 2)
        #expect(step.progress(at: 1) == .init(distance: 0, finished: false))
        #expect(step.progress(at: 2).finished)
    }
}

/// The driver moves the transcript as a finger or a deceleration does: by
/// each frame's delta from where the content is now.
@Suite struct ConversationAutoScrollMotionTests {
    @Test func movesByEachFramesDelta() {
        var motion = ConversationAutoScrollMotion()
        #expect(motion.frame(distance: 40, currentOffsetY: 1000, top: -100, bottom: 2000).offsetY == 960)
        #expect(motion.frame(distance: 100, currentOffsetY: 960, top: -100, bottom: 2000).offsetY == 900)
    }

    /// An older page lands above and the anchor restore shifts the offset
    /// down by the page's height: the next frame carries on from the
    /// restored offset rather than writing the stale coordinate back (which
    /// swapped the rows on screen and landed page after page).
    @Test func carriesOnFromAnAnchorRestore() {
        var motion = ConversationAutoScrollMotion()
        _ = motion.frame(distance: 100, currentOffsetY: 1000, top: -100, bottom: 9000)
        // A 6000-pt page lands: the restore moves 900 to 6900.
        let next = motion.frame(distance: 130, currentOffsetY: 6900, top: -100, bottom: 9000)
        #expect(next.offsetY == 6870)
        #expect(!next.reachedEdge)
    }

    /// A content change between frames that the reader did not cause (a
    /// row's height settling) is kept too.
    @Test func keepsAnOffsetWrittenBetweenFrames() {
        var motion = ConversationAutoScrollMotion()
        _ = motion.frame(distance: 10, currentOffsetY: 500, top: 0, bottom: 2000)
        #expect(motion.frame(distance: 10, currentOffsetY: 520, top: 0, bottom: 2000).offsetY == 520)
    }

    /// The motion stops at either end of the content and says so.
    @Test func stopsAtTheEdges() {
        var up = ConversationAutoScrollMotion()
        let top = up.frame(distance: 80, currentOffsetY: 50, top: 0, bottom: 2000)
        #expect(top.offsetY == 0)
        #expect(top.reachedEdge)
        var down = ConversationAutoScrollMotion()
        let bottom = down.frame(distance: -80, currentOffsetY: 1950, top: 0, bottom: 2000)
        #expect(bottom.offsetY == 2000)
        #expect(bottom.reachedEdge)
    }

    /// No delta, no movement and no edge, even when resting on an edge.
    @Test func restingOnAnEdgeIsNotReachingIt() {
        var motion = ConversationAutoScrollMotion()
        let frame = motion.frame(distance: 0, currentOffsetY: 2000, top: 0, bottom: 2000)
        #expect(frame == .init(offsetY: 2000, reachedEdge: false))
    }
}
