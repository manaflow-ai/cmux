import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

/// Ghostty C callbacks whose thread libghostty does not pin to main deliver
/// their effect on the main thread instead of trapping in
/// `MainActor.assumeIsolated` (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite(.serialized) struct GhosttyCallbackThreadTests {
    /// The font scale reads the configured size from the shared runtime.
    init() { _ = GhosttyRuntime.shared }

    @Test func fontSizeActionFromABackgroundThreadLandsOnMain() async {
        let (_, continuation) = AsyncStream.makeStream(of: TerminalOutgoing.self, bufferingPolicy: .bufferingNewest(1))
        let bridge = SurfaceBridge(input: TerminalInputSink(continuation: continuation))
        let address = UInt(bitPattern: Unmanaged.passUnretained(bridge).toOpaque())
        let onMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            bridge.onFontScaleChange = { _ in done.resume(returning: Thread.isMainThread) }
            Thread.detachNewThread {
                ghosttyFontSizeAction(UnsafeMutableRawPointer(bitPattern: address), GHOSTTY_FONT_SIZE_ACTION_INCREASE,
                                      12, 13, false, true)
            }
        }
        #expect(onMain)
        withExtendedLifetime(bridge) {}
    }

    @Test func fontSizeActionOnMainRunsBeforeItReturns() {
        let (_, continuation) = AsyncStream.makeStream(of: TerminalOutgoing.self, bufferingPolicy: .bufferingNewest(1))
        let bridge = SurfaceBridge(input: TerminalInputSink(continuation: continuation))
        var calls = 0
        bridge.onFontScaleChange = { _ in calls += 1 }
        ghosttyFontSizeAction(Unmanaged.passUnretained(bridge).toOpaque(), GHOSTTY_FONT_SIZE_ACTION_RESET, 13, 12, true, false)
        #expect(calls == 1)
    }
}
