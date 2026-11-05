@testable import CmuxNextCloud
import Foundation
import Testing

/// The relay-first chat's stream (cmuxterm-hq#7086): NDJSON events from the platform's MachineRelay.
@Suite struct CloudRelayChatTests {
    @Test func aTurnReadsToDoneWithItsFirstTextTime() {
        var answer = CloudRelayChat.Answer()
        answer.apply(line: #"{"kind":"queued","reason":"machine_offline"}"#, at: .seconds(1))
        // Still open: it may yet be sent, so it counts as delivered.
        #expect(answer.delivered)
        answer.apply(line: #"{"kind":"sent"}"#, at: .seconds(3))
        #expect(answer.sent)
        answer.apply(line: #"{"kind":"started","session":"s-1","prompt_id":"p-1"}"#, at: .seconds(4))
        answer.apply(line: #"{"kind":"keepalive"}"#, at: .seconds(5))
        answer.apply(line: #"{"kind":"record","seq":3,"record":{}}"#, at: .seconds(6))
        answer.apply(line: #"{"kind":"text","text":"Hel"}"#, at: .seconds(7))
        answer.apply(line: #"{"kind":"text","text":"lo"}"#, at: .seconds(8))
        #expect(!answer.ended)
        answer.apply(line: #"{"kind":"done","stop_reason":"end_turn"}"#, at: .seconds(9))
        #expect(answer.ended)
        #expect(answer.queued)
        #expect(answer.session == "s-1")
        #expect(answer.promptID == "p-1")
        #expect(answer.reply == "Hello")
        #expect(answer.firstText == .seconds(7))
        #expect(answer.total == .seconds(9))
        #expect(answer.stopReason == "end_turn")
        #expect(answer.errorCode == nil)
    }

    @Test func anErrorEndsTheTurnAndJunkIsIgnored() {
        var answer = CloudRelayChat.Answer()
        answer.apply(line: "not json", at: .zero)
        answer.apply(line: #"{"text":"no kind"}"#, at: .zero)
        #expect(!answer.ended)
        answer.apply(line: #"{"kind":"error","code":"cloud.relay.machine_offline","message":"down"}"#, at: .seconds(90))
        #expect(answer.ended)
        #expect(answer.errorCode == "cloud.relay.machine_offline")
        #expect(answer.errorMessage == "down")
        // Ended before the platform sent it: certainly not on the machine.
        #expect(!answer.delivered)
        #expect(answer.stopReason == nil)
        #expect(answer.firstText == nil)
    }

    @Test func doneCarriesTheWholeReplyOverTheStreamedText() {
        var answer = CloudRelayChat.Answer()
        answer.apply(line: #"{"kind":"started","session":"s-1"}"#, at: .seconds(1))
        // A chunk came before the machine's tail was attached: the streamed text lacks it.
        answer.apply(line: #"{"kind":"text","text":"lo"}"#, at: .seconds(2))
        answer.apply(line: #"{"kind":"done","stop_reason":"end_turn","reply":"Hello"}"#, at: .seconds(3))
        #expect(answer.reply == "Hello")
        #expect(answer.firstText == .seconds(2))
        var quiet = CloudRelayChat.Answer()
        quiet.apply(line: #"{"kind":"done","reply":"Hi"}"#, at: .seconds(5))
        #expect(quiet.reply == "Hi")
        #expect(quiet.firstText == .seconds(5))
    }

    @Test func aBrokenStreamMayHaveReachedTheMachine() {
        // The relay answered 200 and then the stream broke, before its `sent` reached the Mac: never sent again.
        var answer = CloudRelayChat.Answer()
        answer.apply(line: #"{"kind":"queued","reason":"machine_offline"}"#, at: .seconds(1))
        answer.broken = true
        answer.errorCode = "cloud.relay.closed"
        #expect(answer.ended)
        #expect(answer.delivered)
    }

    @Test func onlyAMachineIDIsSent() {
        #expect(CloudRelayChat.isMachineID("vm_0123456789abcdefghij"))
        #expect(!CloudRelayChat.isMachineID("vm_short"))
        #expect(!CloudRelayChat.isMachineID("vm_0123456789abcdefghij/../x"))
    }
}
