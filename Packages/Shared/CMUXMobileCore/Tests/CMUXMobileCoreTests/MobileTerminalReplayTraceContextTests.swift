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
        #expect(MobileTerminalReplayTraceContext(encoded: context.encoded)?.attempt == 0)
    }

    /// The fields that separate "waiting on a repair" from "nothing is
    /// coming", and "the lane is dead" from "the surface stopped asking".
    @Test func repairStateRoundTrips() {
        for inFlight in [true, false] {
            for exhausted in [true, false] {
                for connected in [true, false] {
                    let context = MobileTerminalReplayTraceContext(
                        trigger: .retryExhausted,
                        surfaceIsBlank: true,
                        barrierActive: false,
                        attempt: 2,
                        replayInFlight: inFlight,
                        retryExhausted: exhausted,
                        isConnected: connected,
                        terminalEventAgeSeconds: 9
                    )
                    let decoded = MobileTerminalReplayTraceContext(encoded: context.encoded)
                    #expect(decoded == context)
                    #expect(decoded?.replayInFlight == inFlight)
                    #expect(decoded?.retryExhausted == exhausted)
                    #expect(decoded?.isConnected == connected)
                    // 9s rounds down to the 8s bucket.
                    #expect(decoded?.terminalEventAgeSeconds == 8)
                }
            }
        }
    }

    @Test func aLaneThatNeverDeliveredHasNoAge() {
        let never = MobileTerminalReplayTraceContext(
            trigger: .coldAttach, surfaceIsBlank: true, barrierActive: false,
            attempt: 0, terminalEventAgeSeconds: nil
        )
        #expect(MobileTerminalReplayTraceContext(encoded: never.encoded)?
            .terminalEventAgeSeconds == nil)
        let fresh = MobileTerminalReplayTraceContext(
            trigger: .coldAttach, surfaceIsBlank: true, barrierActive: false,
            attempt: 0, terminalEventAgeSeconds: 1
        )
        #expect(MobileTerminalReplayTraceContext(encoded: fresh.encoded)?
            .terminalEventAgeSeconds == 1)
    }

    /// A lane that delivered half a second ago is the healthiest reading
    /// there is. Encoding it like a lane that never delivered would invert
    /// the diagnosis this field exists to give.
    @Test func aSubSecondAgeIsDistinctFromNeverDelivered() {
        let fresh = MobileTerminalReplayTraceContext(
            trigger: .coldAttach, surfaceIsBlank: true, barrierActive: false,
            attempt: 0, terminalEventAgeSeconds: 0
        )
        let never = MobileTerminalReplayTraceContext(
            trigger: .coldAttach, surfaceIsBlank: true, barrierActive: false,
            attempt: 0, terminalEventAgeSeconds: nil
        )
        #expect(fresh.encoded != never.encoded)
        #expect(MobileTerminalReplayTraceContext(encoded: fresh.encoded)?
            .terminalEventAgeSeconds == 0)
        #expect(MobileTerminalReplayTraceContext(encoded: never.encoded)?
            .terminalEventAgeSeconds == nil)
    }

    @Test func everyBucketRoundTripsMonotonically() {
        var previous = -1
        for seconds in [0, 1, 2, 3, 4, 7, 8, 100, 5_000, 100_000] {
            let context = MobileTerminalReplayTraceContext(
                trigger: .coldAttach, surfaceIsBlank: true, barrierActive: false,
                attempt: 0, terminalEventAgeSeconds: seconds
            )
            let decoded = MobileTerminalReplayTraceContext(encoded: context.encoded)
            let age = decoded?.terminalEventAgeSeconds ?? -1
            #expect(age >= previous)
            #expect(age <= seconds)
            previous = age
        }
    }

    @Test func aVeryOldAgeSaturatesInsteadOfWrapping() {
        let ancient = MobileTerminalReplayTraceContext(
            trigger: .coldAttach, surfaceIsBlank: true, barrierActive: false,
            attempt: 0, terminalEventAgeSeconds: 1_000_000
        )
        let decoded = MobileTerminalReplayTraceContext(encoded: ancient.encoded)
        #expect(decoded?.terminalEventAgeSeconds != nil)
        #expect((decoded?.terminalEventAgeSeconds ?? 0) > 0)
        #expect(decoded == ancient)
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
