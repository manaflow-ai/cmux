import Foundation
import Testing
@testable import CmuxNextDaemon

/// An `fs.*` refusal carries its facts in `error_details` next to a plain-string `error`
/// (cmux-tui `fs_ops/stream.rs` `answer`). A Cloud file page saves a symlinked file at the
/// revision an `fs.revision_mismatch` names there (#25581); dropped details read as "deleted".
struct FileSystemErrorDetailsTests {
    @Test func aRevisionMismatchKeepsTheCurrentRevision() throws {
        let line = #"{"id":7,"ok":false,"error":"the file changed since it was read","error_code":"fs.revision_mismatch","error_details":{"current":"s12-m1791100000000"}}"#
        let envelope = try JSONDecoder().decode(LineTransport.Envelope.self, from: Data(line.utf8))
        #expect(envelope.errorCode == "fs.revision_mismatch")
        #expect(envelope.errorDetails?["current"]?.stringValue == "s12-m1791100000000")
    }

    @Test func aMismatchOnAGoneFileSaysNoRevision() throws {
        let line = #"{"id":8,"ok":false,"error":"the file changed since it was read","error_code":"fs.revision_mismatch","error_details":{"current":null}}"#
        let envelope = try JSONDecoder().decode(LineTransport.Envelope.self, from: Data(line.utf8))
        #expect(envelope.errorDetails != nil)
        #expect(envelope.errorDetails?["current"]?.stringValue == nil)
    }

    @Test func aRejectsReasonStillWins() throws {
        let line = #"{"id":9,"ok":false,"error":"no","error_code":"x","reason":"busy","error_details":{"current":"s1-m1"}}"#
        let envelope = try JSONDecoder().decode(LineTransport.Envelope.self, from: Data(line.utf8))
        #expect(envelope.errorDetails?["reason"]?.stringValue == "busy")
    }
}
