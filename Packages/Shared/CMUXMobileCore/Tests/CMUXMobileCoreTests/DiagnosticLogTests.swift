import Foundation
import Testing
import os
@testable import CMUXMobileCore

@Suite struct DiagnosticLogTests {
    private var englishLocale: Locale { Locale(identifier: "en") }

    private enum ClassifiedTestError: Error, DiagnosticFailureProviding {
        case denied

        var diagnosticFailureKind: DiagnosticFailureKind { .admissionDenied }
    }

    /// Await the drain task processing at least `expected` total events, so a
    /// test can assert on a deterministic post-drain state without sleeping.
    /// ``DiagnosticLog/processedCount()`` only grows (eviction does not lower
    /// it), so it is a stable barrier even when the ring is at capacity. The
    /// drain task runs on the cooperative pool; `Task.yield()` lets it advance.
    /// Bounded so a regression that never drains fails instead of hanging.
    private func waitForProcessed(_ log: DiagnosticLog, _ expected: Int) async {
        for _ in 0..<1_000_000 {
            if await log.processedCount() >= expected { return }
            await Task.yield()
        }
        #expect(
            await log.processedCount() >= expected,
            "diagnostic drain did not reach the required barrier"
        )
    }

    /// Await the observer itself instead of treating the ring's processed
    /// count as a callback-delivery barrier. The store increments that count
    /// before the drain task invokes the tap, so those are separate events.
    private func waitForTappedEvents(
        _ received: OSAllocatedUnfairLock<[DiagnosticEvent]>,
        count expected: Int
    ) async {
        for _ in 0..<1_000_000 {
            if received.withLock({ $0.count }) >= expected { return }
            await Task.yield()
        }
        #expect(
            received.withLock({ $0.count }) >= expected,
            "diagnostic event tap did not reach the required barrier"
        )
    }

    /// Record one event and await it draining into the ring, so the next record
    /// never overflows the stream buffer. Draining each event before recording
    /// the next means what survives is governed only by the ring's eviction
    /// (deterministic) and never by `.bufferingNewest`'s pending-drop policy
    /// (timing-dependent).
    private func recordAndDrain(
        _ log: DiagnosticLog,
        _ event: DiagnosticEvent,
        processedAfter: Int
    ) async {
        log.record(event)
        await waitForProcessed(log, processedAfter)
    }

    @Test func recordThenExportRoundTrips() async throws {
        let log = DiagnosticLog(
            capacity: 16,
            buildStamp: "cmux DEV test",
            role: .mobileClient,
            anchorWallNanos: 1_700_000_000_000_000_000,
            anchorMonotonicNanos: 500
        )
        log.record(DiagnosticEvent(code: .connect, tNanos: 500))
        log.record(DiagnosticEvent(code: .pairOk, tNanos: 250_000_500, ms: 250))
        log.record(DiagnosticEvent(
            code: .inputSeqBehind,
            tNanos: 500_000_500,
            surface: 7,
            a: 10,
            b: 20
        ))
        await waitForProcessed(log, 3)

        let report = await log.snapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let humanReadableExport = report.humanReadableExport(locale: englishLocale)
        let text = try #require(String(bytes: humanReadableExport, encoding: .utf8))
        #expect(report.compactExport() == report.humanReadableExport())
        let inputSequenceLine = "2023-11-14 22:13:20.500 UTC | "
            + "Terminal input acknowledgements fell behind "
            + "(Surface: 7, Local sequence: 10, Remote sequence: 20)"
        #expect(text == """
        cmux Iroh and transport report
        Report format: 2
        Generated: 2023-11-14 22:13:21.000 UTC
        Source: iOS client
        Build: cmux DEV test
        Event count: 3

        Timeline (oldest first)
        2023-11-14 22:13:20.000 UTC | Connection attempt started
        2023-11-14 22:13:20.250 UTC | Pairing succeeded (Duration: 250 ms)
        \(inputSequenceLine)

        """)

        let liveData = await log.export()
        let liveText = try #require(String(bytes: liveData, encoding: .utf8))
        let currentConnectTitle = DiagnosticEventPresentation().describe(
            DiagnosticEvent(code: .connect, tNanos: 0)
        ).name
        #expect(liveText.contains(currentConnectTitle))
        #expect(!liveText.contains("anchorWallNs"))
        #expect(!liveText.contains("500,1,,,,,"))
    }

    @Test func duplicateSelectedPathNotificationsDoNotExportFalseChanges() async {
        let log = DiagnosticLog(capacity: 16)
        log.record(DiagnosticEvent(
            code: .selectedPathChanged,
            tNanos: 1_000,
            a: DiagnosticPathKind.relay.rawValue
        ))
        log.record(DiagnosticEvent(
            code: .transportSessionLifecycle,
            tNanos: 2_000,
            a: DiagnosticSessionLifecycleKind.established.rawValue,
            b: Int(CmxTransportSessionPurpose.foregroundControl.rawValue),
            c: 1
        ))
        log.record(DiagnosticEvent(
            code: .selectedPathChanged,
            tNanos: 3_000,
            a: DiagnosticPathKind.relay.rawValue
        ))
        log.record(DiagnosticEvent(
            code: .selectedPathChanged,
            tNanos: 4_000,
            a: DiagnosticPathKind.privateNetwork.rawValue
        ))
        log.record(DiagnosticEvent(
            code: .selectedPathChanged,
            tNanos: 5_000,
            a: DiagnosticPathKind.privateNetwork.rawValue
        ))
        await waitForProcessed(log, 5)

        let report = await log.snapshot()
        #expect(report.events.map(\.code) == [
            .selectedPathChanged,
            .transportSessionLifecycle,
            .selectedPathChanged,
        ])
        #expect(report.events.compactMap(\.diagnosticPathKind) == [
            .relay,
            .privateNetwork,
        ])
        #expect(report.events[1].diagnosticSessionLifecycleKind == .established)
    }

    @Test func ringEvictionDropsOldest() async {
        let log = DiagnosticLog(capacity: 3)
        // Drain each event before recording the next so eviction is governed
        // purely by the ring (not by the stream's bufferingNewest drop policy).
        for i in 0..<6 {
            await recordAndDrain(
                log,
                DiagnosticEvent(code: .connect, tNanos: UInt64(i)),
                processedAfter: i + 1
            )
        }
        #expect(await log.count() == 3)

        // Oldest (tNanos 0,1,2) evicted; newest (3,4,5) retained, in order.
        #expect(await log.snapshot().events.map(\.tNanos) == [3, 4, 5])
    }

    @Test func recordIsNonBlockingUnderBurst() async {
        // A burst far larger than capacity must not block the recorder: every
        // `record` returns synchronously (no await), and the ring stays bounded
        // by capacity once the drain settles. `.bufferingNewest` drops the
        // oldest *pending* events, so the final ring is bounded, not exact.
        let capacity = 64
        let log = DiagnosticLog(capacity: capacity)
        let burst = 50_000
        for i in 0..<burst {
            log.record(DiagnosticEvent(code: .renderGridLag, tNanos: UInt64(i), ms: 1))
        }
        // The recorder never suspended; we reach here immediately. Let the drain
        // settle and confirm the ring never exceeds capacity.
        await waitForProcessed(log, 1)
        let count = await log.count()
        #expect(count >= 1)
        #expect(count <= capacity)
    }

    @Test func circularBufferWrapsAndPreservesChronologicalOrder() async {
        // Drive the O(1) ring past several full wrap cycles and confirm export
        // still yields exactly the newest `capacity` events in record order,
        // proving the head/offset arithmetic is correct across the wrap boundary.
        let capacity = 4
        let log = DiagnosticLog(capacity: capacity)
        let total = 13 // 3 full cycles + 1, so head wraps and lands mid-array
        for i in 0..<total {
            await recordAndDrain(
                log,
                DiagnosticEvent(code: .connect, tNanos: UInt64(i)),
                processedAfter: i + 1
            )
        }
        #expect(await log.count() == capacity)

        // Newest `capacity` events are tNanos 9,10,11,12, in order.
        #expect(await log.snapshot().events.map(\.tNanos) == [9, 10, 11, 12])
    }

    @Test func exportOnEmptyLogHasHeaderOnly() async throws {
        let report = DiagnosticReport(
            role: .unspecified,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let text = try #require(
            String(
                bytes: report.humanReadableExport(locale: englishLocale),
                encoding: .utf8
            )
        )
        #expect(text == """
        cmux Iroh and transport report
        Report format: 2
        Generated: 2023-11-14 22:13:21.000 UTC
        Source: Unspecified runtime
        Event count: 0

        Timeline (oldest first)
        No events recorded.

        """)
        #expect(!text.contains("anchorWallNs"))
        #expect(!text.contains("anchorMonoNs"))
    }

    @Test func exportUsesReadableRelativeTimesWithoutAWallClockAnchor() throws {
        let report = DiagnosticReport(
            role: .macHost,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            events: [
                DiagnosticEvent(code: .endpointStarting, tNanos: 5_000),
                DiagnosticEvent(code: .endpointActive, tNanos: 250_005_000),
            ]
        )

        let text = try #require(
            String(
                bytes: report.humanReadableExport(locale: englishLocale),
                encoding: .utf8
            )
        )
        #expect(text.contains("+0.000 seconds | Iroh endpoint starting"))
        #expect(text.contains("+0.250 seconds | Iroh endpoint active"))
    }

    @Test(.enabled(
        if: LocalizationTestSupport().hasCompiledLocalization(for: Locale(identifier: "ja")),
        "Command-line SwiftPM copies string catalogs without compiling locale resources"
    ))
    func exportUsesJapaneseCatalogCopy() async throws {
        let report = DiagnosticReport(
            role: .macHost,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            events: [
                DiagnosticEvent(code: .reachabilityChanged, tNanos: 5_000, a: 0),
            ]
        )

        let locale = Locale(identifier: "ja")
        let text = try #require(
            String(
                bytes: report.humanReadableExport(locale: locale),
                encoding: .utf8
            )
        )
        #expect(text.contains("cmux Irohとトランスポートのレポート"))
        #expect(text.contains("+0.000 秒 | ネットワーク到達性が変更されました（ネットワーク: オフライン）"))
        #expect(await report.humanReadableText(locale: locale) == text)
    }

    @Test func transportDiagnosticCodesAreStableAndAppendOnly() {
        #expect(DiagnosticEventCode.transportDialStarted.rawValue == 25)
        #expect(DiagnosticEventCode.transportDialConnected.rawValue == 26)
        #expect(DiagnosticEventCode.transportDialFailed.rawValue == 27)
        #expect(DiagnosticEventCode.hostAuthenticated.rawValue == 28)
        #expect(DiagnosticEventCode.rpcReady.rawValue == 29)
        #expect(DiagnosticEventCode.recoveryStarted.rawValue == 30)
        #expect(DiagnosticEventCode.recoverySucceeded.rawValue == 31)
        #expect(DiagnosticEventCode.recoveryFailed.rawValue == 32)
        #expect(DiagnosticEventCode.endpointStarting.rawValue == 33)
        #expect(DiagnosticEventCode.endpointActive.rawValue == 34)
        #expect(DiagnosticEventCode.endpointStopped.rawValue == 35)
        #expect(DiagnosticEventCode.endpointFailed.rawValue == 36)
        #expect(DiagnosticEventCode.relayPolicyRefreshStarted.rawValue == 37)
        #expect(DiagnosticEventCode.relayPolicyRefreshSucceeded.rawValue == 38)
        #expect(DiagnosticEventCode.relayPolicyRefreshFailed.rawValue == 39)
        #expect(DiagnosticEventCode.selectedPathChanged.rawValue == 40)
        #expect(DiagnosticEventCode.sessionClosed.rawValue == 41)
        #expect(DiagnosticEventCode.routeUnavailable.rawValue == 42)
        #expect(DiagnosticEventCode.retryScheduled.rawValue == 43)
        #expect(DiagnosticEventCode.discoveryStarted.rawValue == 44)
        #expect(DiagnosticEventCode.discoverySucceeded.rawValue == 45)
        #expect(DiagnosticEventCode.discoveryFailed.rawValue == 46)
        #expect(DiagnosticEventCode.admissionSucceeded.rawValue == 47)
        #expect(DiagnosticEventCode.admissionFailed.rawValue == 48)
        #expect(DiagnosticEventCode.hostAuthenticationFailed.rawValue == 49)
        #expect(DiagnosticEventCode.rpcFailed.rawValue == 50)
        #expect(DiagnosticEventCode.transportSessionLifecycle.rawValue == 51)
        #expect(DiagnosticEventCode.transportCloseAttribution.rawValue == 54)
        #expect(DiagnosticEventCode.transportPathEvent.rawValue == 55)
        #expect(DiagnosticEventCode.browserStreamLifecycle.rawValue == 56)
        #expect(DiagnosticEventCode.browserInputReplayed.rawValue == 57)
        #expect(DiagnosticEventCode.browserEditableFocus.rawValue == 58)
        #expect(DiagnosticEventCode.browserPanelCreateResolved.rawValue == 59)
        #expect(DiagnosticEventCode.simulatorStreamLifecycle.rawValue == 60)
        #expect(DiagnosticEventCode.simulatorFrameLifecycle.rawValue == 61)
        #expect(DiagnosticEventCode.simulatorInputLifecycle.rawValue == 62)
        #expect(DiagnosticEventCode.simulatorCoordinateMapped.rawValue == 63)
        #expect(DiagnosticEventCode.simulatorOwnershipChanged.rawValue == 64)
        #expect(DiagnosticEventCode.appFeatureAction.rawValue == 65)
        #expect(DiagnosticEventCode.transportDialSessionLinked.rawValue == 77)
        #expect(DiagnosticEventCode.transportDialCancelled.rawValue == 78)
        #expect(DiagnosticEventCode.transportCloseReason.rawValue == 79)
        #expect(Set(DiagnosticEventCode.allCases.map(\.rawValue)).count == DiagnosticEventCode.allCases.count)
    }

    @Test func appEventCorrelationIsStableWithinProcessAndDoesNotRetainRawIdentifier() async {
        let log = DiagnosticLog(capacity: 4)
        let opaqueIdentifier = "workspace-sensitive-identifier"

        log.recordAppEvent(.workspaceOpenStarted, correlationID: opaqueIdentifier)
        log.recordAppEvent(.workspaceOpenSucceeded, correlationID: opaqueIdentifier)

        await waitForProcessed(log, 2)
        let report = await log.snapshot()
        #expect(report.events.count == 2)
        #expect(report.events[0].surface == report.events[1].surface)
        #expect(report.events[0].surface != nil)
        let encoded = try? JSONEncoder().encode(report)
        let text = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!text.contains(opaqueIdentifier))
    }

    @Test func typedAppEventDetailKeepsCategoricalValuesOutOfTheCountAPI() async {
        let log = DiagnosticLog(capacity: 2)

        log.recordAppEvent(
            .terminalShortcutChanged,
            detail: .toolbarConfigurationAction(.shortcutReordered)
        )

        await waitForProcessed(log, 1)
        let report = await log.snapshot()
        #expect(report.events.count == 1)
        #expect(report.events[0].a == DiagnosticAppEventKind.terminalShortcutChanged.rawValue)
        #expect(report.events[0].c == DiagnosticToolbarConfigurationAction.shortcutReordered.rawValue)
    }

    @Test func closeAttributionAndPathEventsExposeTypedPayloads() {
        let close = DiagnosticEvent(
            code: .transportCloseAttribution,
            tNanos: 10,
            ms: 42,
            a: 2,
            b: DiagnosticFailureKind.connectionClosed.rawValue,
            c: 7
        )
        let path = DiagnosticEvent(
            code: .transportPathEvent,
            tNanos: 11,
            a: 3,
            b: DiagnosticPathKind.privateNetwork.rawValue,
            c: 7
        )

        #expect(close.diagnosticFailureKind == .connectionClosed)
        #expect(close.diagnosticSessionID == 7)
        #expect(path.diagnosticPathKind == .privateNetwork)
        #expect(path.diagnosticSessionID == 7)
    }

    @Test func diagnosticTaxonomyHasStableRawValuesAndRedactedMappings() {
        #expect(DiagnosticTransportKind(.iroh) == .iroh)
        #expect(DiagnosticTransportKind(.tailscale) == .tailscale)
        #expect(DiagnosticTransportKind(.websocket) == .websocket)
        #expect(DiagnosticTransportKind(.debugLoopback) == .debugLoopback)
        #expect(CmxAttachTransportKind.iroh.diagnosticTransportKind.rawValue == 1)
        #expect(DiagnosticFailureKind.cancelled.rawValue == 20)
        #expect(DiagnosticFailureKind.transportIdleTimedOut.rawValue == 21)
        #expect(DiagnosticFailureKind.admissionLeaseExpired.rawValue == 22)
        #expect(DiagnosticFailureKind.admissionRevalidationFailed.rawValue == 23)
        #expect(DiagnosticFailureKind.sendQueueOverflow.rawValue == 24)
        #expect(DiagnosticFailureKind.routeGated.rawValue == 25)
        #expect(DiagnosticFailureKind.payloadTooLarge.rawValue == 26)
        #expect(DiagnosticFailureKind.resourceLimitReached.rawValue == 27)
        #expect(DiagnosticFailureKind.attachmentCountLimitReached.rawValue == 28)
        #expect(DiagnosticFailureKind.attachmentAggregateSizeLimitReached.rawValue == 29)
        #expect(DiagnosticFailureKind.localStateUnavailable.rawValue == 30)
        #expect(DiagnosticAppEventKind.onboardingStageViewed.rawValue == 41)
        #expect(DiagnosticAppEventKind.fileDiffCacheHit.rawValue == 352)
        #expect(DiagnosticAppEventKind.photoPickerDismissed.rawValue == 459)
        #expect(DiagnosticAppEventKind.toastPresented.rawValue == 537)
        #expect(DiagnosticAppEventKind.toastDismissed.rawValue == 541)
        #expect(DiagnosticAppEventKind.irohSettingsOpened.rawValue == 610)
        #expect(DiagnosticAppEventKind.verboseDiagnosticsShared.rawValue == 636)
        #expect(DiagnosticAppEventKind.dictationStopTimedOut.rawValue == 659)
        #expect(DiagnosticAppEventKind.pairedMacStoreWriteStarted.rawValue == 660)
        #expect(DiagnosticSimulatorStreamLifecycle.stopFailed.rawValue == 12)
        #expect(
            Set(DiagnosticAppEventKind.allCases.map(\.rawValue)).count
                == DiagnosticAppEventKind.allCases.count
        )
        #expect(
            Set(DiagnosticFailureKind.allCases.map(\.rawValue)).count
                == DiagnosticFailureKind.allCases.count
        )
        #expect(DiagnosticFailureKind.unknown.rawValue == 255)
        #expect(DiagnosticSessionLifecycleKind.established.rawValue == 1)
        #expect(DiagnosticSessionLifecycleKind.controlOwnerReleased.rawValue == 2)
        #expect(DiagnosticSessionLifecycleKind.controlReadFailed.rawValue == 3)
        #expect(DiagnosticSessionLifecycleKind.controlWriteFailed.rawValue == 4)
        #expect(DiagnosticSessionLifecycleKind.remoteClosed.rawValue == 5)
        #expect(DiagnosticSessionLifecycleKind.closedSessionEvicted.rawValue == 6)
        #expect(DiagnosticSessionLifecycleKind.applicationLaneFailed.rawValue == 7)
        #expect(DiagnosticSessionLifecycleKind.runtimeDeactivated.rawValue == 8)
        #expect(DiagnosticSessionLifecycleKind.runtimeReconfigured.rawValue == 9)
        #expect(DiagnosticSessionLifecycleKind.explicitlyInvalidated.rawValue == 10)
        #expect(DiagnosticSessionLifecycleKind.allPathsClosed.rawValue == 11)
        #expect(DiagnosticPathKind(.unavailable) == .unknown)
        #expect(DiagnosticPathKind(.direct) == .direct)
        #expect(DiagnosticPathKind(.privateNetwork) == .privateNetwork)
        #expect(
            DiagnosticPathKind(.managedRelay(provider: "provider", region: "region")) == .relay
        )
        #expect(
            DiagnosticPathKind(
                .customRelay(displayName: "private", provider: "provider", region: "region")
            ) == .relay
        )
    }

    @Test func failureClassifierPrefersTypedErrorsAndBoundsSystemErrors() {
        #expect(DiagnosticFailureKind.classify(ClassifiedTestError.denied) == .admissionDenied)
        #expect(DiagnosticFailureKind.classify(CancellationError()) == .cancelled)
        #expect(
            DiagnosticFailureKind.classify(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            ) == .timedOut
        )
        #expect(
            DiagnosticFailureKind.classify(
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.EHOSTUNREACH.rawValue)
                )
            ) == .hostUnreachable
        )
        #expect(
            DiagnosticFailureKind.classify(
                NSError(domain: "contains-sensitive-provider-text", code: 9)
            ) == .unknown
        )
    }

    @Test func snapshotOrdersEventsMapsWallDatesAndSummarizesLatestFailure() async {
        let log = DiagnosticLog(
            capacity: 8,
            buildStamp: "cmux DEV diag",
            role: .mobileClient,
            anchorWallNanos: 1_700_000_000_000_000_000,
            anchorMonotonicNanos: 1_000
        )
        log.record(
            DiagnosticEvent(
                code: .transportDialConnected,
                tNanos: 2_000,
                a: Int(DiagnosticTransportKind.iroh.rawValue),
                c: 7
            )
        )
        log.record(
            DiagnosticEvent(
                code: .transportDialFailed,
                tNanos: 3_000,
                a: Int(DiagnosticTransportKind.iroh.rawValue),
                b: Int(DiagnosticFailureKind.noRoute.rawValue),
                c: 8
            )
        )
        await waitForProcessed(log, 2)

        let generatedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let report = await log.snapshot(generatedAt: generatedAt)
        #expect(report.schemaVersion == DiagnosticReport.currentSchemaVersion)
        #expect(report.role == .mobileClient)
        #expect(report.generatedAt == generatedAt)
        #expect(report.buildStamp == "cmux DEV diag")
        #expect(report.events.map(\.tNanos) == [2_000, 3_000])
        #expect(report.events[0].diagnosticTransportKind == .iroh)
        #expect(report.events[0].diagnosticAttemptID == 7)
        #expect(report.events[1].diagnosticFailureKind == .noRoute)
        #expect(report.lastFailureKind == .noRoute)
        #expect(report.lastFailureEvent?.code == .transportDialFailed)
        #expect(report.lastSuccessEvent?.code == .transportDialConnected)
        #expect(
            abs((report.lastTransportConnectionDate?.timeIntervalSince1970 ?? 0) - 1_700_000_000.000_001) < 0.000_001
        )
        #expect(
            abs((report.lastConnectionSuccessDate?.timeIntervalSince1970 ?? 0) - 1_700_000_000.000_001) < 0.000_001
        )
        #expect(
            abs((report.lastFailureDate?.timeIntervalSince1970 ?? 0) - 1_700_000_000.000_002) < 0.000_001
        )
    }

    @Test func hostAdmissionCountsAsAConnectionSuccess() {
        let report = DiagnosticReport(
            role: .macHost,
            anchorWallNanos: 1_000_000_000,
            anchorMonotonicNanos: 10,
            events: [DiagnosticEvent(code: .admissionSucceeded, tNanos: 20)]
        )

        #expect(report.lastTransportConnectionDate == nil)
        #expect(report.lastConnectionSuccessDate != nil)
    }

    @Test func reportInitializerSortsInputAndUsesSafeFallbackFailureKinds() {
        let report = DiagnosticReport(
            role: .macHost,
            generatedAt: Date(timeIntervalSince1970: 5),
            anchorWallNanos: 5_000_000_000,
            anchorMonotonicNanos: 100,
            buildStamp: "cmux\nDEV/@sensitive=value",
            events: [
                DiagnosticEvent(code: .routeUnavailable, tNanos: 300),
                DiagnosticEvent(code: .endpointActive, tNanos: 200),
            ]
        )

        #expect(report.events.map(\.tNanos) == [200, 300])
        #expect(report.lastFailureKind == .noRoute)
        #expect(report.buildStamp == "cmuxDEVsensitivevalue")
        #expect(!report.buildStamp.contains("\n"))
        #expect(!report.buildStamp.contains("/"))
        #expect(!report.buildStamp.contains("@"))
        #expect(!report.buildStamp.contains("="))
    }

    @Test func everyTypedFailureEventContributesToLatestFailureHelpers() {
        let failureCodes: [DiagnosticEventCode] = [
            .transportDialFailed,
            .recoveryFailed,
            .endpointFailed,
            .relayPolicyRefreshFailed,
            .sessionClosed,
            .routeUnavailable,
            .discoveryFailed,
            .admissionFailed,
            .hostAuthenticationFailed,
            .rpcFailed,
        ]

        for (index, code) in failureCodes.enumerated() {
            let event = DiagnosticEvent(
                code: code,
                tNanos: UInt64(index + 2),
                b: DiagnosticFailureKind.protocolViolation.rawValue
            )
            let report = DiagnosticReport(
                anchorWallNanos: 1_000_000_000,
                anchorMonotonicNanos: 1,
                events: [event]
            )
            #expect(report.lastFailureEvent == event)
            #expect(report.lastFailureKind == .protocolViolation)
            #expect(report.lastFailureDate != nil)
        }
    }

    @Test func cancelledDialOutcomesDoNotCountAsFailures() {
        let realFailure = DiagnosticEvent(
            code: .rpcFailed,
            tNanos: 2,
            b: DiagnosticFailureKind.protocolViolation.rawValue
        )
        let abandonedDial = DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: 3,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.cancelled.rawValue,
            c: 7
        )

        let onlyAbandoned = DiagnosticReport(
            anchorWallNanos: 1_000_000_000,
            anchorMonotonicNanos: 1,
            events: [abandonedDial]
        )
        #expect(onlyAbandoned.lastFailureEvent == nil)
        #expect(onlyAbandoned.lastFailureKind == nil)
        #expect(onlyAbandoned.lastFailureDate == nil)

        let abandonedAfterRealFailure = DiagnosticReport(
            anchorWallNanos: 1_000_000_000,
            anchorMonotonicNanos: 1,
            events: [realFailure, abandonedDial]
        )
        #expect(abandonedAfterRealFailure.lastFailureEvent == realFailure)
        #expect(abandonedAfterRealFailure.lastFailureKind == .protocolViolation)
    }

    @Test func gatedDialRefusalsReportRouteGatedNotTimedOut() {
        // A connect-registry gate refusal is instantaneous and never touched
        // the network. It used to be classified as `.timedOut`, fabricating
        // sub-30ms timeout failures that poisoned `lastFailureEvent`.
        let gatedRefusal = DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: 2,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.routeGated.rawValue,
            c: 7
        )
        let report = DiagnosticReport(
            anchorWallNanos: 1_000_000_000,
            anchorMonotonicNanos: 1,
            events: [gatedRefusal]
        )
        #expect(report.lastFailureKind == .routeGated)
        #expect(report.lastFailureKind != .timedOut)
        #expect(report.lastFailureEvent == gatedRefusal)
    }

    @Test func clearStartsFreshBoundedSessionAndResetsAnchors() async {
        let log = DiagnosticLog(
            capacity: 2,
            role: .macHost,
            anchorWallNanos: 1_000,
            anchorMonotonicNanos: 10
        )
        log.record(DiagnosticEvent(code: .endpointStarting, tNanos: 11))
        await waitForProcessed(log, 1)

        await log.clear(anchorWallNanos: 9_000, anchorMonotonicNanos: 90)
        #expect(await log.count() == 0)
        #expect(await log.processedCount() == 0)
        let emptySnapshot = await log.snapshot(generatedAt: Date(timeIntervalSince1970: 9))
        #expect(emptySnapshot.role == .macHost)
        #expect(emptySnapshot.anchorWallNanos == 9_000)
        #expect(emptySnapshot.anchorMonotonicNanos == 90)
        #expect(emptySnapshot.events.isEmpty)

        log.record(DiagnosticEvent(code: .endpointActive, tNanos: 91))
        await waitForProcessed(log, 1)
        let freshSnapshot = await log.snapshot()
        #expect(freshSnapshot.events.map(\.code) == [.endpointActive])
        #expect(freshSnapshot.wallDate(for: freshSnapshot.events[0]) != nil)
    }

    @Test func clearBarrierPreventsBufferedOldSessionEventsFromReappearing() async {
        let log = DiagnosticLog(capacity: 8)
        for index in 0..<10_000 {
            log.record(DiagnosticEvent(code: .rpcFailed, tNanos: UInt64(index)))
        }

        await log.clear(anchorWallNanos: 10_000, anchorMonotonicNanos: 100)

        #expect(await log.count() == 0)
        #expect(await log.processedCount() == 0)

        log.record(DiagnosticEvent(code: .rpcReady, tNanos: 101))
        await waitForProcessed(log, 1)
        #expect((await log.snapshot()).events.map(\.code) == [.rpcReady])
    }

    @Test func consecutiveClearsChainBoundedSessionsInOrder() async {
        let log = DiagnosticLog(
            capacity: 2,
            anchorWallNanos: 100,
            anchorMonotonicNanos: 1
        )
        log.record(DiagnosticEvent(code: .endpointStarting, tNanos: 2))
        await waitForProcessed(log, 1)

        await log.clear(anchorWallNanos: 1_000, anchorMonotonicNanos: 10)
        log.record(DiagnosticEvent(code: .endpointActive, tNanos: 11))
        await waitForProcessed(log, 1)

        await log.clear(anchorWallNanos: 2_000, anchorMonotonicNanos: 20)
        let empty = await log.snapshot()
        #expect(empty.anchorWallNanos == 2_000)
        #expect(empty.anchorMonotonicNanos == 20)
        #expect(empty.events.isEmpty)
        #expect(await log.processedCount() == 0)

        log.record(DiagnosticEvent(code: .rpcReady, tNanos: 21))
        await waitForProcessed(log, 1)
        #expect((await log.snapshot()).events.map(\.code) == [.rpcReady])
    }

    @Test func reportCodableContainsNoUnboundedErrorOrRouteFields() throws {
        let report = DiagnosticReport(
            role: .mobileClient,
            generatedAt: Date(timeIntervalSince1970: 1),
            anchorWallNanos: 1_000_000_000,
            anchorMonotonicNanos: 1,
            buildStamp: "cmux 1.2.3",
            events: [
                DiagnosticEvent(
                    code: .transportDialFailed,
                    tNanos: 2,
                    a: Int(DiagnosticTransportKind.iroh.rawValue),
                    b: Int(DiagnosticFailureKind.authorizationFailed.rawValue),
                    c: 1
                ),
            ]
        )

        let data = try JSONEncoder().encode(report)
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(!text.contains("endpoint"))
        #expect(!text.contains("address"))
        #expect(!text.contains("relayURL"))
        #expect(!text.contains("token"))
        #expect(!text.contains("errorDescription"))
        #expect(try JSONDecoder().decode(DiagnosticReport.self, from: data) == report)
    }

    @Test func reportCapsEventsAndSanitizesDecodedBuildStamp() throws {
        let oversized = (0..<(DiagnosticReport.maximumEventCount + 2)).map { index in
            DiagnosticEvent(code: .connect, tNanos: UInt64(index))
        }
        let report = DiagnosticReport(buildStamp: "safe", events: oversized)
        #expect(report.events.count == DiagnosticReport.maximumEventCount)
        #expect(report.events.first?.tNanos == 2)

        let encoded = try JSONEncoder().encode(report)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["buildStamp"] = "cmux\n/private/@identity=value"
        let hostileData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: hostileData)
        #expect(decoded.buildStamp == "cmuxprivateidentityvalue")
    }

    @Test func reportDecoderRejectsAnOversizedEventArrayBeforeDecodingTheExtraEvent() throws {
        let maximum = DiagnosticReport.maximumEventCount
        let exactEvents = (0..<maximum).map { index in
            DiagnosticEvent(code: .connect, tNanos: UInt64(index))
        }
        let exactReport = DiagnosticReport(events: exactEvents)
        let exactData = try JSONEncoder().encode(exactReport)
        #expect(try JSONDecoder().decode(DiagnosticReport.self, from: exactData).events.count == maximum)

        var object = try #require(
            JSONSerialization.jsonObject(with: exactData) as? [String: Any]
        )
        var encodedEvents = try #require(object["events"] as? [[String: Any]])
        encodedEvents.append(["malformed": true])
        object["events"] = encodedEvents
        let oversizedData = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try JSONDecoder().decode(DiagnosticReport.self, from: oversizedData)
            Issue.record("Expected the oversized diagnostic report to be rejected")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription == "Diagnostic report exceeds the maximum event count.")
        } catch {
            Issue.record("Expected a maximum-count error before decoding the malformed extra event: \(error)")
        }
    }

    @Test func reportInitializerBoundsBeforeStableOrdering() {
        let maximum = DiagnosticReport.maximumEventCount
        var events = [
            DiagnosticEvent(code: .connect, tNanos: 99_999),
            DiagnosticEvent(code: .pairOk, tNanos: 88_888),
        ]
        events += (0..<maximum).map { index in
            DiagnosticEvent(code: .rpcReady, tNanos: UInt64(maximum - index))
        }

        let report = DiagnosticReport(events: events)

        #expect(report.events.count == maximum)
        #expect(report.events.first?.tNanos == 1)
        #expect(report.events.last?.tNanos == UInt64(maximum))
        #expect(!report.events.contains(where: { $0.tNanos == 99_999 || $0.tNanos == 88_888 }))
    }

    @Test func eventTapDeliversRetainedEventsInOrder() async {
        let log = DiagnosticLog(capacity: 8)
        let received = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])
        log.setEventTap { event in
            received.withLock { $0.append(event) }
        }

        let first = DiagnosticEvent(code: .connect, tNanos: 1)
        let second = DiagnosticEvent(code: .pairOk, tNanos: 2)
        log.record(first)
        log.record(second)
        await waitForProcessed(log, 2)
        await waitForTappedEvents(received, count: 2)

        #expect(received.withLock { $0 } == [first, second])
    }

    @Test func eventTapSkipsDedupedSelectedPathRepeats() async {
        let log = DiagnosticLog(capacity: 8)
        let received = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])
        log.setEventTap { event in
            received.withLock { $0.append(event) }
        }

        let relay = DiagnosticEvent(
            code: .selectedPathChanged,
            tNanos: 1,
            a: DiagnosticPathKind.relay.rawValue
        )
        let repeatRelay = DiagnosticEvent(
            code: .selectedPathChanged,
            tNanos: 2,
            a: DiagnosticPathKind.relay.rawValue
        )
        log.record(relay)
        log.record(repeatRelay)
        await waitForProcessed(log, 2)
        await waitForTappedEvents(received, count: 1)

        #expect(received.withLock { $0 } == [relay])
    }

    @Test func eventTapNeverDeliversEventsQueuedBeforeInstallation() async {
        // Regression: record() admits events onto the drain stream before the
        // drain task delivers them. Installing the tap in that window must not
        // deliver the already-admitted events: the tap floor is the ingress
        // admission sequence, not the drain position. Recording a burst and
        // installing the tap immediately (no drain sync) makes the pre-fix
        // race overwhelmingly likely to deliver stale events.
        let log = DiagnosticLog(capacity: 4096)
        let burst = 500
        for index in 1...burst {
            log.record(DiagnosticEvent(code: .connect, tNanos: UInt64(index)))
        }
        let received = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])
        log.setEventTap { event in
            received.withLock { $0.append(event) }
        }
        await waitForProcessed(log, burst)
        #expect(received.withLock { $0.isEmpty })

        // Events admitted after installation still flow.
        let live = DiagnosticEvent(code: .pairOk, tNanos: UInt64(burst + 1))
        log.record(live)
        await waitForProcessed(log, burst + 1)
        await waitForTappedEvents(received, count: 1)
        #expect(received.withLock { $0 } == [live])
    }

    @Test func eventTapDoesNotReplayHistoryAndCanBeRemoved() async {
        let log = DiagnosticLog(capacity: 8)
        log.record(DiagnosticEvent(code: .connect, tNanos: 1))
        await waitForProcessed(log, 1)

        let received = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])
        log.setEventTap { event in
            received.withLock { $0.append(event) }
        }
        let live = DiagnosticEvent(code: .pairOk, tNanos: 2)
        log.record(live)
        await waitForProcessed(log, 2)
        await waitForTappedEvents(received, count: 1)
        #expect(received.withLock { $0 } == [live])

        log.setEventTap(nil)
        log.record(DiagnosticEvent(code: .pairFail, tNanos: 3))
        await waitForProcessed(log, 3)
        #expect(received.withLock { $0 } == [live])
    }
}
