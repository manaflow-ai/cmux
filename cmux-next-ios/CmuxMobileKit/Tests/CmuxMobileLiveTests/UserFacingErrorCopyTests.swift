import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The link, acpmux and service errors read as sentences: no codes, no type names,
/// no HTTP numbers. LinkController's status-line fragments come from the same table.
@Suite struct UserFacingErrorCopyTests {
    @Test func linkErrorsSayWhatHappenedAndWhatToDo() {
        #expect(LinkError(code: "timeout", message: "").errorDescription == "Your Mac didn't answer in time. Try again.")
        #expect(LinkError(code: "offline", message: "").errorDescription
            == "Your Mac isn't connected. Open cmux on your Mac, then try again.")
        #expect(LinkError(code: LinkError.unauthorized, message: "Token Refused by edge").errorDescription
            == "Your session expired. Sign in again.")
        // The Mac's own sentence wins; a code-like message never shows.
        #expect(LinkError(code: "offline", message: "Connection changed. Try again.").errorDescription
            == "Connection changed. Try again.")
        #expect(LinkError(code: "attach", message: "terminal_not_found").errorDescription
            == "Something went wrong talking to your Mac. Try again.")
        let bridged = (LinkError(code: "timeout", message: "") as any Error).localizedDescription
        #expect(!bridged.contains("LinkError") && !bridged.contains("error 1"))
    }

    @Test func statusLineFragmentsKeepTheirWordsAndNeverACode() {
        #expect(LinkController.reason(LinkError(code: "timeout", message: "")) == "the Mac didn't answer in time")
        #expect(LinkController.reason(LinkError(code: "offline", message: "")) == "the Mac is offline")
        #expect(LinkController.reason(LinkError(code: "not_admitted", message: "")) == "the Mac refused this phone")
        #expect(LinkController.reason(LinkError(code: "eof", message: "")) == "the connection to the Mac failed")
        #expect(LinkController.reason(LinkError(code: "no-link", message: "Not connected to the Mac")) == "Not connected to the Mac")
        struct Opaque: Error {}
        #expect(LinkController.reason(Opaque()) == "the connection to the Mac failed")
    }

    /// Review of the merge at e4aa15cf: the base's copy took only capitalized prose, so every
    /// Cloud carrier error read as "the connection to the Mac failed" (a locked iPhone included).
    @Test func cloudErrorsSayItIsTheCloudMachineAndWhatToDo() {
        // The carrier's own message for it (CloudCarrierKey) never wins over the table's sentence.
        #expect(LinkError(code: "keychain.locked", message: "the Keychain is locked until this iPhone is unlocked").errorDescription
            == "Unlock this iPhone to open the Cloud machine, then try again.")
        #expect(LinkController.reason(LinkError(code: "keychain.locked", message: "")) == "this iPhone is locked")
        #expect(LinkController.reason(LinkError(code: "carrier.handshake", message: "")) == "the Cloud machine didn't prove it's yours")
        let dropped = LinkError(code: "closed", message: "The connection to the Cloud machine dropped")
        #expect(LinkController.reason(dropped) == "The connection to the Cloud machine dropped")
        #expect(!(dropped.errorDescription ?? "").contains("Mac"))
    }

    @Test func pairingRefusalsNeverShowARawMessage() {
        #expect(LinkPairing.refusalText(LinkError(code: "pairing", message: "bad_key")) == "the connection to the Mac failed")
        #expect(LinkPairing.refusalText(LinkError(code: "busy", message: "")) == "the Mac is already pairing this iPhone")
    }

    @MainActor @Test func rpcErrorsSayTheReasonOrTheMacsSentence() {
        typealias RPC = AcpmuxConnection.RPCError
        #expect(RPC(code: -32000, message: "x", reason: "trust.pending").errorDescription == "Trust this folder on your Mac first.")
        #expect(RPC(code: -32004, message: "no pending permission p1", reason: nil).errorDescription == "Already answered on your Mac.")
        #expect(RPC(code: 0, message: "Not connected to your Mac", reason: nil).errorDescription == "Not connected to your Mac")
        #expect(RPC(code: -32603, message: "internal error", reason: nil).errorDescription == "Your Mac couldn't do that. Try again.")
        #expect(RPC(code: -32000, message: "paced", reason: "list.paced", retryAfterMs: 500).errorDescription
            == "Your Mac is busy. Try again in a moment.")
        // In the chat, an agent's own refusal says what is wrong; a dump never shows.
        #expect(AcpmuxSessionSource.message(RPC(code: -32000, message: "model unavailable", reason: nil)) == "model unavailable")
        #expect(AcpmuxSessionSource.message(RPC(code: -32000, message: "LinkError(code: x)", reason: nil))
            == "Your Mac couldn't do that. Try again.")
        #expect(UserFacingError.message(RPC(code: -32603, message: "internal error", reason: nil)) == "Your Mac couldn't do that. Try again.")
    }

    @Test func serviceFailuresNeverShowAStatusOrACode() {
        typealias Failure = LiveAPI.Failure
        #expect(Failure(status: 401, code: "unauthorized", message: "token refresh failed").errorDescription
            == "Your session expired. Sign in again.")
        #expect(Failure(status: 503, code: "http_503", message: "<html>Bad Gateway</html>").errorDescription
            == "The Cloud service isn't available right now. Try again in a moment.")
        #expect(Failure(status: 429, code: "rate_limited", message: "").errorDescription == "Too many requests. Wait a moment and try again.")
        #expect(Failure(status: 403, code: "not_member", message: "You're not a member of this team.").errorDescription
            == "You're not a member of this team.")
        #expect(Failure(status: 403, code: "not_member", message: "no").errorDescription == "You don't have access to that.")
        #expect(Failure(status: 0, code: "bad_reply", message: "no Macs in the reply").errorDescription
            == "The Cloud service couldn't do that. Try again in a moment.")
    }
}
