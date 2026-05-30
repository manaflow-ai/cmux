import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct ScreenReadRequestCodableTests {
    @Test func roundTrips() throws {
        let req = ScreenReadRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            format: .text, region: .viewport, wrap: .preserve, trim: true)
        let back = try JSONDecoder().decode(ScreenReadRequest.self,
                                            from: JSONEncoder().encode(req))
        #expect(back == req)
    }

    @Test func defaultsAreSafe() {
        let req = ScreenReadRequest(handle: .uuid(UUID()))
        #expect(req.format == .text)
        #expect(req.region == .viewport)
        #expect(req.wrap == .preserve)
        #expect(req.trim == true)
    }
}
