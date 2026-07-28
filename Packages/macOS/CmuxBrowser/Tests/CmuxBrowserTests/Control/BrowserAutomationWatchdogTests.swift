import Foundation
import Testing

@testable import CmuxBrowser

@MainActor
@Suite("Browser automation watchdog")
struct BrowserAutomationWatchdogTests {
    @Test("A completed liveness probe preserves the current browser process")
    func responsiveProbeDoesNotRecover() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog(
            sleep: { duration in
                try await ContinuousClock().sleep(for: duration)
            }
        )

        let outcome = await watchdog.recoverIfUnresponsive(
            observedInstanceID: UUID(),
            probes: [{ finish in finish() }],
            recover: {
                recoveryCount += 1
                return true
            }
        )

        #expect(outcome == .responsive)
        #expect(recoveryCount == 0)
    }

    @Test("A missing liveness callback replaces the unresponsive browser process")
    func timedOutProbeRecovers() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog(sleep: { _ in })

        let outcome = await watchdog.recoverIfUnresponsive(
            observedInstanceID: UUID(),
            probes: [{ _ in }],
            recover: {
                recoveryCount += 1
                return true
            }
        )

        #expect(outcome == .recovered)
        #expect(recoveryCount == 1)
    }

    @Test("A WebView replaced during the probe is not replaced a second time")
    func supersededProbeDoesNotRecoverAgain() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog(sleep: { _ in })

        let outcome = await watchdog.recoverIfUnresponsive(
            observedInstanceID: UUID(),
            probes: [{ _ in }],
            recover: {
                recoveryCount += 1
                return false
            }
        )

        #expect(outcome == .superseded)
        #expect(recoveryCount == 1)
    }

    @Test("A responsive snapshot cannot mask a missing JavaScript callback")
    func oneResponsiveChannelStillRecovers() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog(sleep: { _ in })

        let outcome = await watchdog.recoverIfUnresponsive(
            observedInstanceID: UUID(),
            probes: [
                { _ in },
                { finish in finish() },
            ],
            recover: {
                recoveryCount += 1
                return true
            }
        )

        #expect(outcome == .recovered)
        #expect(recoveryCount == 1)
    }

    @Test("All browser callback channels must respond before the pipeline is healthy")
    func allResponsiveChannelsPreserveBrowserProcess() async {
        var recoveryCount = 0
        let watchdog = BrowserAutomationWatchdog()

        let outcome = await watchdog.recoverIfUnresponsive(
            observedInstanceID: UUID(),
            probes: [
                { finish in finish() },
                { finish in finish() },
            ],
            recover: {
                recoveryCount += 1
                return true
            }
        )

        #expect(outcome == .responsive)
        #expect(recoveryCount == 0)
    }

    @Test("Concurrent checks for one browser instance share one liveness operation")
    func concurrentChecksShareOneRecovery() async {
        var probeCount = 0
        var recoveryCount = 0
        var pendingProbeCompletions: [@MainActor @Sendable () -> Void] = []
        let (probeStarts, probeStartsContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        var probeStartsIterator = probeStarts.makeAsyncIterator()
        let (followerJoins, followerJoinsContinuation) = AsyncStream.makeStream(of: Void.self)
        var followerJoinsIterator = followerJoins.makeAsyncIterator()
        let watchdog = BrowserAutomationWatchdog()
        let observedInstanceID = UUID()
        let probe: BrowserAutomationWatchdog.Probe = { finish in
            probeCount += 1
            pendingProbeCompletions.append(finish)
            probeStartsContinuation.yield()
        }
        let recover: BrowserAutomationWatchdog.Recovery = {
            recoveryCount += 1
            return true
        }

        let firstCheck = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(
                observedInstanceID: observedInstanceID,
                probes: [probe],
                recover: recover
            )
        }
        let firstProbeStarted: Void? = await probeStartsIterator.next()
        #expect(firstProbeStarted != nil)

        let secondCheck = Task { @MainActor in
            // This synchronous signal and the same-actor call form one run-to-suspension region:
            // the test cannot resume on MainActor until recovery appends this follower and awaits.
            followerJoinsContinuation.yield()
            return await watchdog.recoverIfUnresponsive(
                observedInstanceID: observedInstanceID,
                probes: [probe],
                recover: recover
            )
        }
        let followerJoined: Void? = await followerJoinsIterator.next()
        #expect(followerJoined != nil)

        #expect(probeCount == 1)
        let completions = pendingProbeCompletions
        for completion in completions {
            completion()
        }
        let firstOutcome = await firstCheck.value
        let secondOutcome = await secondCheck.value

        #expect(firstOutcome == .responsive)
        #expect(secondOutcome == .responsive)
        #expect(probeCount == 1)
        #expect(recoveryCount == 0)
        probeStartsContinuation.finish()
        followerJoinsContinuation.finish()
    }

    @Test("Cancelling the leading check cancels callers sharing its recovery")
    func leadingCancellationCancelsSharedRecovery() async {
        var probeCount = 0
        let (probeStarts, probeStartsContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        var probeStartsIterator = probeStarts.makeAsyncIterator()
        let (followerJoins, followerJoinsContinuation) = AsyncStream.makeStream(of: Void.self)
        var followerJoinsIterator = followerJoins.makeAsyncIterator()
        let watchdog = BrowserAutomationWatchdog()
        let observedInstanceID = UUID()
        let probe: BrowserAutomationWatchdog.Probe = { _ in
            probeCount += 1
            probeStartsContinuation.yield()
        }
        let recover: BrowserAutomationWatchdog.Recovery = { true }

        let firstCheck = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(
                observedInstanceID: observedInstanceID,
                probes: [probe],
                recover: recover
            )
        }
        let firstProbeStarted: Void? = await probeStartsIterator.next()
        #expect(firstProbeStarted != nil)

        let secondCheck = Task { @MainActor in
            followerJoinsContinuation.yield()
            return await watchdog.recoverIfUnresponsive(
                observedInstanceID: observedInstanceID,
                probes: [probe],
                recover: recover
            )
        }
        let followerJoined: Void? = await followerJoinsIterator.next()
        #expect(followerJoined != nil)
        firstCheck.cancel()

        let firstOutcome = await firstCheck.value
        let secondOutcome = await secondCheck.value
        #expect(firstOutcome == .cancelled)
        #expect(secondOutcome == .cancelled)
        #expect(probeCount == 1)
        probeStartsContinuation.finish()
        followerJoinsContinuation.finish()
    }

    @Test("Cancelling a joined check does not retain it until the leader finishes")
    func followerCancellationDoesNotWaitForLeader() async {
        var probeCompletion: (@MainActor @Sendable () -> Void)?
        let (probeStarts, probeStartsContinuation) = AsyncStream.makeStream(of: Void.self)
        var probeStartsIterator = probeStarts.makeAsyncIterator()
        let (followerJoins, followerJoinsContinuation) = AsyncStream.makeStream(of: Void.self)
        var followerJoinsIterator = followerJoins.makeAsyncIterator()
        let watchdog = BrowserAutomationWatchdog()
        let observedInstanceID = UUID()
        let probe: BrowserAutomationWatchdog.Probe = { finish in
            probeCompletion = finish
            probeStartsContinuation.yield()
        }

        let leader = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(
                observedInstanceID: observedInstanceID,
                probes: [probe],
                recover: { true }
            )
        }
        let probeStarted: Void? = await probeStartsIterator.next()
        #expect(probeStarted != nil)

        let follower = Task { @MainActor in
            followerJoinsContinuation.yield()
            return await watchdog.recoverIfUnresponsive(
                observedInstanceID: observedInstanceID,
                probes: [probe],
                recover: { true }
            )
        }
        let followerJoined: Void? = await followerJoinsIterator.next()
        #expect(followerJoined != nil)
        follower.cancel()

        #expect(await follower.value == .cancelled)
        probeCompletion?()
        #expect(await leader.value == .responsive)
        probeStartsContinuation.finish()
        followerJoinsContinuation.finish()
    }

    @Test("Owner invalidation cancels joined checks without recovering the stale instance")
    func ownerInvalidationSupersedesSharedRecovery() async {
        var probeCompletion: (@MainActor @Sendable () -> Void)?
        var recoveryCount = 0
        let (probeStarts, probeStartsContinuation) = AsyncStream.makeStream(of: Void.self)
        var probeStartsIterator = probeStarts.makeAsyncIterator()
        let (followerJoins, followerJoinsContinuation) = AsyncStream.makeStream(of: Void.self)
        var followerJoinsIterator = followerJoins.makeAsyncIterator()
        let watchdog = BrowserAutomationWatchdog()
        let observedInstanceID = UUID()
        let probe: BrowserAutomationWatchdog.Probe = { finish in
            probeCompletion = finish
            probeStartsContinuation.yield()
        }

        let leader = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(
                observedInstanceID: observedInstanceID,
                probes: [probe],
                recover: {
                    recoveryCount += 1
                    return true
                }
            )
        }
        let probeStarted: Void? = await probeStartsIterator.next()
        #expect(probeStarted != nil)

        let follower = Task { @MainActor in
            followerJoinsContinuation.yield()
            return await watchdog.recoverIfUnresponsive(
                observedInstanceID: observedInstanceID,
                probes: [probe],
                recover: {
                    recoveryCount += 1
                    return true
                }
            )
        }
        let followerJoined: Void? = await followerJoinsIterator.next()
        #expect(followerJoined != nil)
        watchdog.invalidate()

        #expect(await follower.value == .cancelled)
        probeCompletion?()
        #expect(await leader.value == .superseded)
        #expect(recoveryCount == 0)
        probeStartsContinuation.finish()
        followerJoinsContinuation.finish()
    }

    @Test("A newer browser instance supersedes every caller checking the old instance")
    func newerInstanceSupersedesOldRecovery() async {
        var firstProbeCount = 0
        var firstRecoveryCount = 0
        var firstProbeCompletion: (@MainActor @Sendable () -> Void)?
        var secondRecoveryCount = 0
        var secondProbeCompletion: (@MainActor @Sendable () -> Void)?
        let (probeStarts, probeStartsContinuation) = AsyncStream.makeStream(
            of: UUID.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        var probeStartsIterator = probeStarts.makeAsyncIterator()
        let (followerJoins, followerJoinsContinuation) = AsyncStream.makeStream(of: Void.self)
        var followerJoinsIterator = followerJoins.makeAsyncIterator()
        let watchdog = BrowserAutomationWatchdog()
        let firstInstanceID = UUID()
        let secondInstanceID = UUID()
        let firstProbe: BrowserAutomationWatchdog.Probe = { finish in
            firstProbeCount += 1
            firstProbeCompletion = finish
            probeStartsContinuation.yield(firstInstanceID)
        }
        let secondProbe: BrowserAutomationWatchdog.Probe = { finish in
            secondProbeCompletion = finish
            probeStartsContinuation.yield(secondInstanceID)
        }

        let firstLeader = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(
                observedInstanceID: firstInstanceID,
                probes: [firstProbe],
                recover: {
                    firstRecoveryCount += 1
                    return true
                }
            )
        }
        let firstStarted = await probeStartsIterator.next()
        #expect(firstStarted == firstInstanceID)

        let firstFollower = Task { @MainActor in
            followerJoinsContinuation.yield()
            return await watchdog.recoverIfUnresponsive(
                observedInstanceID: firstInstanceID,
                probes: [firstProbe],
                recover: {
                    firstRecoveryCount += 1
                    return true
                }
            )
        }
        let followerJoined: Void? = await followerJoinsIterator.next()
        #expect(followerJoined != nil)
        #expect(firstProbeCount == 1)

        let secondLeader = Task { @MainActor in
            await watchdog.recoverIfUnresponsive(
                observedInstanceID: secondInstanceID,
                probes: [secondProbe],
                recover: {
                    secondRecoveryCount += 1
                    return true
                }
            )
        }
        let secondStarted = await probeStartsIterator.next()
        #expect(secondStarted == secondInstanceID)
        #expect(await firstFollower.value == .superseded)

        secondProbeCompletion?()
        #expect(await secondLeader.value == .responsive)

        firstProbeCompletion?()
        #expect(await firstLeader.value == .superseded)
        #expect(firstRecoveryCount == 0)
        #expect(secondRecoveryCount == 0)
        probeStartsContinuation.finish()
        followerJoinsContinuation.finish()
    }
}
