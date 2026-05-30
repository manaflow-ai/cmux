import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct SurfaceHandleTests {
    @Test func parsesUUIDForm() throws {
        let raw = "550e8400-e29b-41d4-a716-446655440000"
        let parsed = try #require(SurfaceHandle.parse(raw))
        guard case .uuid(let u) = parsed else { Issue.record("not uuid"); return }
        #expect(u == UUID(uuidString: raw))
    }

    @Test func parsesRefForm() throws {
        let parsed = try #require(SurfaceHandle.parse("surface:1"))
        guard case .ref(let kind, let ord) = parsed else { Issue.record("not ref"); return }
        #expect(kind == "surface")
        #expect(ord == 1)
    }

    @Test func parsesOtherKinds() throws {
        let parsed = try #require(SurfaceHandle.parse("workspace:42"))
        guard case .ref(let kind, let ord) = parsed else { Issue.record("not ref"); return }
        #expect(kind == "workspace")
        #expect(ord == 42)
    }

    @Test(arguments: ["", "surface:", "surface:abc", ":1", "surface:-1", "surface:1:2", "not-a-uuid", "Surface:1"])
    func rejectsInvalid(_ s: String) {
        #expect(SurfaceHandle.parse(s) == nil)
    }

    @Test func codableRoundTrip() throws {
        let h: SurfaceHandle = .ref(kind: "surface", ordinal: 7)
        let data = try JSONEncoder().encode(h)
        #expect(try JSONDecoder().decode(SurfaceHandle.self, from: data) == h)
    }
}
