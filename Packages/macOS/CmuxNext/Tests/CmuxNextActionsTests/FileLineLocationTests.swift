import CmuxNextActions
import Testing

struct FileLineLocationTests {
    @Test(arguments: ["0", "-1", "+42", "1.5", "1e3", " 42", "42 ", "42:0", "42:7:8", "42-1", "10000001", "42-10000001", "true", "٤٢", "42:7-8"])
    func refusesInvalidLocations(_ text: String) {
        #expect(FileLineLocation(text) == nil)
    }

    @Test(arguments: ["42", "42:7", "42-50", "10000000", "42:10000000"])
    func numericLocationsRoundTrip(_ text: String) {
        #expect(FileLineLocation(text)?.argument == text)
    }
}
