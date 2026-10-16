import Testing

@testable import CMUXMobileCore

@Suite("Replay trace context encoding")
struct MobileTerminalReplayTraceContextTests {
    @Test func everyTriggerRoundTripsWithBothFlags() {
        for trigger in MobileTerminalReplayTrigger.allCases {
            for blank in [true, false] {
                for barrier in [true, false] {
                    let context = MobileTerminalReplayTraceContext(
                        trigger: trigger,
                        surfaceIsBlank: blank,
                        barrierActive: barrier,
                        attempt: 3
                    )
                    #expect(MobileTerminalReplayTraceContext(encoded: context.encoded) == context)
                }
            }
        }
    }

    @Test func attemptClampsToTheEncodableRange() {
        let context = MobileTerminalReplayTraceContext(
            trigger: .failureRetry,
            surfaceIsBlank: true,
            barrierActive: true,
            attempt: 99
        )
        #expect(context.attempt == MobileTerminalReplayTraceContext.maxAttempt)
        #expect(MobileTerminalReplayTraceContext(encoded: context.encoded) == context)
    }

    @Test func negativeAttemptClampsToZero() {
        let context = MobileTerminalReplayTraceContext(
            trigger: .coldAttach,
            surfaceIsBlank: false,
            barrierActive: false,
            attempt: -4
        )
        #expect(context.attempt == 0)
        #expect(context.encoded == MobileTerminalReplayTrigger.coldAttach.rawValue)
    }

    /// An older consumer must not read a future trigger as `unknown`: that
    /// would silently attribute a new codepath's stalls to the wrong bucket.
    @Test func unknownTriggerDecodesToNilRatherThanUnknown() {
        let futureTrigger = 0xFE
        #expect(MobileTerminalReplayTraceContext(encoded: futureTrigger) == nil)
        #expect(MobileTerminalReplayTraceContext(encoded: -1) == nil)
    }

    @Test func flagsAreIndependentOfTheTriggerBits() {
        let blankOnly = MobileTerminalReplayTraceContext(
            trigger: .outputReset, surfaceIsBlank: true, barrierActive: false, attempt: 0
        )
        let barrierOnly = MobileTerminalReplayTraceContext(
            trigger: .outputReset, surfaceIsBlank: false, barrierActive: true, attempt: 0
        )
        #expect(blankOnly.encoded != barrierOnly.encoded)
        #expect(MobileTerminalReplayTraceContext(encoded: blankOnly.encoded)?.surfaceIsBlank == true)
        #expect(MobileTerminalReplayTraceContext(encoded: barrierOnly.encoded)?.surfaceIsBlank == false)
        #expect(MobileTerminalReplayTraceContext(encoded: barrierOnly.encoded)?.barrierActive == true)
    }
}
