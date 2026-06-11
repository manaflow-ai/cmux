import Foundation
import Testing
@testable import CmuxSwiftRender

/// SPIKE STUB (not for merge): coverage for the throwaway `.textField`
/// lowering that exists to prove in-process input fidelity.
@Suite struct TextFieldStubTests {
    let interp = SwiftViewInterpreter()

    @Test func textFieldLowersPlaceholderAndBindingName() {
        let node = interp.evaluate("""
        VStack {
            TextField("Type here", text: $name)
        }
        """)
        let field = node?.children.first
        #expect(field?.kind == .textField)
        #expect(field?.text == "Type here")
        #expect(field?.binding == "name")
    }

    @Test func textFieldSurvivesCodableRoundTrip() throws {
        // The IR crosses the wire to the remote worker; the stub kind must
        // encode/decode like every other node so a file using it doesn't
        // break the remote lane.
        let node = RenderNode(kind: .textField, text: "ph", binding: "name")
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(RenderNode.self, from: data)
        #expect(decoded == node)
    }
}
