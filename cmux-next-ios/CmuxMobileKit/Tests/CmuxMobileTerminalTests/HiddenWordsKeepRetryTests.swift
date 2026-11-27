#if os(iOS)
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-27: "Hidden-error changes keep Retry tested. When connection text is hidden,
/// a test still checks that a long outage shows Retry or Reconnect.."
///
/// A page whose connection words are hidden (connecting, reattaching: `quietLine` and the
/// stalled panel's notice are nil) still shows Retry once the outage outlasts the bound; a
/// page that says why (offline, failed) shows it at once. #61760 found the menu's Reconnect
/// dead for every reattach after the words went; this keeps the panel's Retry from going the
/// same way. `scripts/lint-hidden-words-keep-retry.py` fails CI if this file or its checks go.
@MainActor @Suite struct HiddenWordsKeepRetryTests {
    /// Every down state. A new `TerminalConnectionState` case fails to compile in
    /// ``isDown(_:)`` until it is listed here and decided.
    static let downStates: [TerminalConnectionState] = [
        .connecting(mac: nil), .connecting(mac: "Studio"),
        .reattaching(mac: nil), .reattaching(mac: "Studio"),
        .offline(mac: nil), .offline(mac: "Studio"),
        .failed(message: "daemon channel closed"),
    ]

    static func isDown(_ state: TerminalConnectionState) -> Bool {
        switch state {
        case .connecting, .reattaching, .offline, .failed: true
        case .attached: false
        }
    }

    @Test func everyDownStateIsListed() {
        #expect(Self.downStates.allSatisfy(Self.isDown))
        #expect(!Self.isDown(.attached))
    }

    @Test func aLongOutageShowsRetryWithItsWordsHidden() {
        let hidden = Self.downStates.filter { TerminalLoadStalledPanel.notice($0) == nil }
        #expect(!hidden.isEmpty, "connecting and reattaching hide their words")
        for state in hidden {
            #expect(state.quietLine == nil, "\(state): hidden words")
            #expect(TerminalLoadWatch.stage(state, waited: .seconds(600)) == .stalled, "\(state): a long outage")
            #expect(TerminalLoadWatch.stage(state, waited: TerminalLoadWatch.bound) == .stalled, "\(state): at the bound")
            #expect(TerminalLoadStalledPanel.offersRetry(state), "\(state): Retry with no words")
        }
    }

    @Test func everyDownStateShowsRetryPastTheBound() {
        for state in Self.downStates {
            #expect(TerminalLoadWatch.stage(state, waited: TerminalLoadWatch.bound) == .stalled, "\(state)")
            #expect(TerminalLoadStalledPanel.offersRetry(state), "\(state)")
        }
        #expect(!TerminalLoadStalledPanel.offersRetry(.attached))
    }
}
#endif
