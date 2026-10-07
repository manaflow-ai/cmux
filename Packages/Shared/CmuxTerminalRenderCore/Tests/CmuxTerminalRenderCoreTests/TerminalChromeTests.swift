import CmuxTerminalRenderCore
import Testing

@Suite("terminal chrome")
struct TerminalChromeTests {
    @Test("a fast direct path shows the path only; relayed or slow shows the RTT and emphasis")
    func badge() {
        let fast = TerminalChrome(path: .direct, rttMilliseconds: 12.4, connection: .connected, hasContent: true, ended: false)
        #expect(fast.badge == TerminalChrome.Badge(path: .direct, rttMilliseconds: nil, isEmphasized: false))
        #expect(fast.banner == nil)
        let slow = TerminalChrome(path: .direct, rttMilliseconds: 80.6, connection: .connected, hasContent: true, ended: false)
        #expect(slow.badge == TerminalChrome.Badge(path: .direct, rttMilliseconds: 81, isEmphasized: true))
        let relayed = TerminalChrome(path: .relayed, rttMilliseconds: 30, connection: nil, hasContent: true, ended: false)
        #expect(relayed.badge == TerminalChrome.Badge(path: .relayed, rttMilliseconds: 30, isEmphasized: true))
    }

    @Test("the banner follows the connection; a drop after content reads as reconnecting")
    func banner() {
        #expect(TerminalChrome(path: nil, rttMilliseconds: nil, connection: .connecting, hasContent: false, ended: false).banner == .connecting)
        #expect(TerminalChrome(path: nil, rttMilliseconds: nil, connection: .connecting, hasContent: true, ended: false).banner
            == .reconnecting(attempt: 1))
        let dropped = TerminalChrome(path: .direct, rttMilliseconds: 10, connection: .reconnecting(attempt: 3), hasContent: true, ended: false)
        #expect(dropped.banner == .reconnecting(attempt: 3) && dropped.badge == nil)
        #expect(TerminalChrome(path: nil, rttMilliseconds: nil, connection: .offline, hasContent: true, ended: false).banner == .offline)
    }

    @Test("an ended stream shows neither: its notice says why")
    func ended() {
        let chrome = TerminalChrome(path: .direct, rttMilliseconds: 10, connection: .offline, hasContent: true, ended: true)
        #expect(chrome.badge == nil && chrome.banner == nil)
    }
}
