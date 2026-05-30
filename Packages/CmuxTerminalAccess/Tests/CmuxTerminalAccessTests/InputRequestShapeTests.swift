import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct InputRequestShapeTests {
    @Test func textWithSubmit() {
        let r = InputRequest(handle: .ref(kind: "surface", ordinal: 1),
                             payload: .text("hi", submit: true), focusSurface: false)
        if case .text(let s, let submit) = r.payload {
            #expect(s == "hi")
            #expect(submit)
        } else {
            Issue.record("not .text")
        }
    }

    @Test func focusSurfaceDefaultsFalse() {
        let r = InputRequest(handle: .uuid(UUID()), payload: .focus(gained: true))
        #expect(r.focusSurface == false)
    }
}
