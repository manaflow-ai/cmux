import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines `set-attach-visibility`, `cancel-creating-input`, `clear-history` and the lease requests send, and that they stay
/// ungated (the app sent them before the daemon advertised their capabilities). These bytes are the contract the
/// generated types (swift_app bindings, family TerminalIO) keep with the hand-written ones they replaced.
struct TerminalIOUngatedRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    @Test func setAttachVisibility() throws {
        #expect(try line(SetAttachVisibilityRequest(surface: 4, visible: false))
            == #"{"cmd":"set-attach-visibility","id":7,"surface":4,"visible":false}"#)
        #expect(SetAttachVisibilityRequest.requiredCapability == nil)
    }

    @Test func cancelCreatingInput() throws {
        #expect(try line(CancelCreatingInputRequest(terminalID: "t_1"))
            == #"{"cmd":"cancel-creating-input","id":7,"terminal_id":"t_1"}"#)
        #expect(CancelCreatingInputRequest.requiredCapability == nil)
    }

    @Test func clearHistorySendsTheFallbackKeyOnlyWhenSet() throws {
        #expect(try line(ClearHistoryRequest(surface: 4)) == #"{"cmd":"clear-history","id":7,"surface":4}"#)
        let mods = #"{"alt":false,"caps_lock":false,"control":false,"num_lock":false,"shift":false,"super":"#
        #expect(try line(ClearHistoryRequest(surface: 4, fallbackKey: .command("k")))
            == #"{"cmd":"clear-history","fallback_key":{"action":"press","consumed_mods":"# + mods + #"false},"#
            + #""key":"k","macos_option_as_alt":true,"mods":"# + mods + #"true},"unshifted_codepoint":"k","utf8":""},"#
            + #""id":7,"surface":4}"#)
        #expect(ClearHistoryRequest.requiredCapability == nil)
    }

    @Test func leaseRequests() throws {
        #expect(try line(ReleaseAttachedViewSizeRequest(surface: 4, lease: "l1"))
            == #"{"cmd":"release-attached-view-size","id":7,"lease":"l1","surface":4}"#)
        #expect(try line(DetachAttachedViewRequest(surface: 4, lease: "l1"))
            == #"{"cmd":"detach-attached-view","id":7,"lease":"l1","surface":4}"#)
        #expect(try line(SetSizeCountsRequest(surface: 4, lease: "l1", counts: false))
            == #"{"cmd":"set-size-counts","counts":false,"id":7,"lease":"l1","surface":4}"#)
        #expect(try line(SetSizeCountsRequest(surface: 4, lease: "l1", counts: nil))
            == #"{"cmd":"set-size-counts","id":7,"lease":"l1","surface":4}"#)
        #expect(ReleaseAttachedViewSizeRequest.requiredCapability == nil)
        #expect(DetachAttachedViewRequest.requiredCapability == nil)
        #expect(SetSizeCountsRequest.requiredCapability == nil)
    }
}
