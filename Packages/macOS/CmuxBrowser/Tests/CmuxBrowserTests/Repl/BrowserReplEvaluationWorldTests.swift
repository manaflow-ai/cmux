import Testing
import WebKit

@testable import CmuxBrowser

/// `frame.evaluate`'s `world` is decided once at the driver boundary: the
/// same value picks the world the source runs in (and so whether it runs
/// with a user gesture) and whether what the page opens meanwhile goes to
/// the session. An omitted world is the page's, as Playwright's evaluate;
/// any other value than `"page"` or `"agent"` fails with `invalid` before
/// anything runs, so no value runs page script outside the session's input
/// window.
@MainActor
@Suite("Evaluation world")
struct BrowserReplEvaluationWorldTests {
    @Test func anOmittedWorldIsThePagesAndOpensTheInputWindow() throws {
        let world = try BrowserReplEvaluationWorld(parameter: nil)
        #expect(world == .page)
        #expect(world.holdsSessionInput)
        #expect(BrowserReplSessionWorld().evaluationWorld(world) === WKContentWorld.page)
    }

    @Test func pageAndAgentAreTheirWorlds() throws {
        let session = BrowserReplSessionWorld()
        let page = try BrowserReplEvaluationWorld(parameter: "page")
        let agent = try BrowserReplEvaluationWorld(parameter: "agent")
        #expect(page.holdsSessionInput)
        #expect(!agent.holdsSessionInput)
        #expect(session.evaluationWorld(page) === WKContentWorld.page)
        #expect(session.evaluationWorld(agent) === session.agent)
    }

    @Test(arguments: ["", "Page", "AGENT", "cmux-driver", "cmux-capture-mask", "main", "page "] as [String])
    func anUnknownWorldNameIsInvalid(_ name: String) {
        #expect(Self.refusal(name)?.code == "invalid", "\(name) was taken as a world")
    }

    @Test func aWorldThatIsNotAStringIsInvalid() {
        for value: Any in [NSNull(), 1, true, ["page"], ["world": "page"]] {
            #expect(Self.refusal(value)?.code == "invalid", "\(value) was taken as a world")
        }
    }

    private static func refusal(_ parameter: Any?) -> BrowserReplDriverError? {
        do {
            _ = try BrowserReplEvaluationWorld(parameter: parameter)
            return nil
        } catch let error as BrowserReplDriverError {
            return error
        } catch {
            return BrowserReplDriverError(code: "unexpected", message: "\(error)")
        }
    }
}
