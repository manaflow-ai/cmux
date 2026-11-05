import Testing
@testable import CmuxNextCloud

struct NativeCloudExecutableRefusalTests {
    @Test func eachRefusalNamesItsCheck() {
        #expect(NativeCloudExecutableRefusal.signing("cmux-tui", -67062).description.contains("cmux-tui signature check failed (OSStatus -67062)"))
        let publisher = NativeCloudExecutableRefusal.publisher(expected: "ABCDE12345", app: "ABCDE12345", binary: nil)
        #expect(publisher.description == "native executable refused: team ABCDE12345 expected, app ABCDE12345, cmux-tui none")
        #expect("\(NativeCloudExecutableRefusal.peer)".contains("broker peer"))
    }
}
