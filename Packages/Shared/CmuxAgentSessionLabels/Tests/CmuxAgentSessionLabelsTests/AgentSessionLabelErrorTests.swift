import Foundation
import Testing

@testable import CmuxAgentSessionLabels

struct AgentSessionLabelErrorTests {
    /// Every message a command line prints, pinned as text.
    ///
    /// Without this, the reflected form of each case happens to contain the same
    /// path and record substrings the store tests look for, so the sentences
    /// could be changed or removed with every test still passing.
    @Test(arguments: [
        (AgentSessionLabelError.emptyLabel, "a session label cannot be empty"),
        (.labelTooLong(length: 130, maximum: 120),
         "a session label is at most 120 characters, got 130"),
        (.labelTooManyBytes(bytes: 900, maximum: 512),
         "a session label is at most 512 bytes, got 900"),
        (.disallowedCharacter(scalar: Unicode.Scalar(0x2028)!),
         "a session label cannot contain U+2028"),
        (.disallowedCharacter(scalar: Unicode.Scalar(0x0A)!),
         "a session label cannot contain U+000A"),
        (.emptyKeyField(field: "session id"),
         "a session label needs a non-empty session id"),
        (.keyFieldTooLong(field: "agent", length: 300, maximum: 200),
         "a session label's agent is at most 200 characters, got 300"),
        (.malformedStore(path: "/s/labels.json", reason: "the file is empty"),
         "/s/labels.json is not a readable session label store: the file is empty"),
        (.unreadableFile(path: "/s/labels.json", reason: "permission denied"),
         "/s/labels.json could not be read: permission denied"),
        (.unwritableFile(path: "/s/labels.json", reason: "disk full"),
         "/s/labels.json could not be written: disk full")
    ])
    func printsOneSentence(error: AgentSessionLabelError, sentence: String) {
        #expect(error.description == sentence)
    }
}
