import AppKit
import Testing

@testable import CmuxFoundation

@Suite("NSResponder.responderChain(contains:)")
@MainActor
struct NSResponderChainContainsTests {
    @Test("Finds a target reachable through the next-responder chain")
    func findsReachableTarget() {
        let a = NSView()
        let b = NSView()
        let c = NSView()
        a.nextResponder = b
        b.nextResponder = c
        #expect(a.responderChain(contains: c))
        #expect(a.responderChain(contains: b))
        #expect(a.responderChain(contains: a))
    }

    @Test("Returns false when the target is not in the chain")
    func missingTarget() {
        let a = NSView()
        let b = NSView()
        let unrelated = NSView()
        a.nextResponder = b
        #expect(!a.responderChain(contains: unrelated))
    }

    @Test("Stops after 64 hops on a cyclic chain instead of looping forever")
    func boundsCyclicChain() {
        let a = NSView()
        let b = NSView()
        a.nextResponder = b
        b.nextResponder = a
        let unrelated = NSView()
        #expect(!a.responderChain(contains: unrelated))
    }
}
