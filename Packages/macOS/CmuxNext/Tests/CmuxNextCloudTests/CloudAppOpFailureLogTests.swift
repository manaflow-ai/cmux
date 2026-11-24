import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// The log names a Cloud op's failure by its code and details: a daemon `apps.unknown` ("no such app") says what
/// the daemon's catalog held, while ``CloudAppOpFailure/description`` stays the person's text.
@Suite struct CloudAppOpFailureLogTests {
    @Test func theLogCarriesTheCodeAndDetails() {
        let failure = CloudAppOpFailure(code: "apps.unknown", message: "no such app", details: .object([
            "app": .string("cmux/cloud"),
            "packages": .array([.string("cmux/demo")]),
        ]))
        #expect(failure.description == "no such app")
        #expect(failure.logDescription == #"apps.unknown: no such app details={"app":"cmux/cloud","packages":["cmux/demo"]}"#)
        #expect(CloudAppOpFailure.logText(failure) == failure.logDescription)
    }

    @Test func aFailureWithoutCodeOrDetailsLogsItsMessage() {
        #expect(CloudAppOpFailure(code: "", message: "gone").logDescription == "gone")
        #expect(CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "x").logDescription == "cmux.cloud.bad_response: x")
    }

    @Test func anotherErrorLogsAsItDescribesItself() {
        struct Other: Error, CustomStringConvertible { var description: String { "other" } }
        #expect(CloudAppOpFailure.logText(Other()) == "other")
    }
}
