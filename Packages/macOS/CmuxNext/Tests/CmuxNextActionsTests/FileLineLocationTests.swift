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

    private struct Invalid: Error {}

    @Test func anActionsLineArgumentIsAStringOrAWholeNumber() throws {
        #expect(try FileLineLocation.argument(nil, orThrow: Invalid()) == nil)
        #expect(try FileLineLocation.argument(.string("42:7"), orThrow: Invalid())?.argument == "42:7")
        #expect(try FileLineLocation.argument(.int(42), orThrow: Invalid())?.argument == "42")
    }

    @Test(arguments: [ActionValue.string("0"), .string("42:7:8"), .int(0), .int(-3), .bool(true)])
    func aCallerThatSkipsTheSchemaStillGetsItsLineRefused(_ value: ActionValue) {
        #expect(throws: Invalid.self) { try FileLineLocation.argument(value, orThrow: Invalid()) }
    }
}
