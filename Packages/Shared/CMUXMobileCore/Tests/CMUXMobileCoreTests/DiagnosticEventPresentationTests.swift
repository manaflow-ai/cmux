import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct DiagnosticEventPresentationTests {
    private var englishPresentation: DiagnosticEventPresentation {
        DiagnosticEventPresentation(locale: Locale(identifier: "en"))
    }

    /// Case names are shipped telemetry vocabulary (Sentry grouping keys), so a
    /// rename is a breaking change this test makes visible.
    @Test func pinsEventCodeNames() {
        #expect(DiagnosticEventPresentation().name(DiagnosticEventCode.transportDialFailed) == "transportDialFailed")
        #expect(DiagnosticEventPresentation().name(DiagnosticEventCode.endpointFailed) == "endpointFailed")
        #expect(DiagnosticEventPresentation().name(DiagnosticEventCode.pairFail) == "pairFail")
        #expect(DiagnosticEventPresentation().name(DiagnosticEventCode.sessionClosed) == "sessionClosed")
        #expect(DiagnosticEventPresentation().name(DiagnosticEventCode.retryScheduled) == "retryScheduled")
        #expect(DiagnosticEventPresentation().name(DiagnosticEventCode.hostAuthenticationFailed) == "hostAuthenticationFailed")
    }

    @Test func pinsTaxonomyNames() {
        #expect(DiagnosticEventPresentation().name(DiagnosticFailureKind.policyUnavailable) == "policyUnavailable")
        #expect(DiagnosticEventPresentation().name(DiagnosticFailureKind.identityMismatch) == "identityMismatch")
        #expect(DiagnosticEventPresentation().name(DiagnosticFailureKind.authorizationFailed) == "authorizationFailed")
        #expect(DiagnosticEventPresentation().name(DiagnosticTransportKind.iroh) == "iroh")
        #expect(DiagnosticEventPresentation().name(DiagnosticPathKind.relay) == "relay")
        #expect(DiagnosticEventPresentation().name(DiagnosticRuntimeRole.mobileClient) == "mobileClient")
        #expect(DiagnosticEventPresentation().name(DiagnosticAppLifecyclePhase.background) == "background")
        #expect(DiagnosticEventPresentation().name(DiagnosticSimulatorFrameLifecycle.cachedSent) == "cachedSent")
        #expect(DiagnosticEventPresentation().name(DiagnosticSimulatorInputLifecycle.rejectedLocked) == "rejectedLocked")
        #expect(DiagnosticEventPresentation().name(DiagnosticSimulatorInputKind.hardwareButton) == "hardwareButton")
        #expect(DiagnosticEventPresentation().name(DiagnosticSimulatorHardwareButtonKind.appSwitcher) == "appSwitcher")
        #expect(DiagnosticEventPresentation().name(DiagnosticSimulatorOwnershipState.otherConnection) == "otherConnection")
        #expect(DiagnosticEventPresentation().name(DiagnosticSimulatorCoordinateState.outsideImage) == "outsideImage")
    }

    @Test func describesDialFailure() {
        let event = DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: 1,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.policyUnavailable.rawValue,
            c: 42
        )
        let described = englishPresentation.describe(event)
        #expect(described.name == "Transport dial failed")
        #expect(described.fields == [
            .init(key: "transport", value: "Iroh"),
            .init(key: "failure", value: "Relay policy unavailable"),
            .init(key: "attempt", value: "42"),
        ])
    }

    @Test func describesRetryDelayAndCloseAttribution() {
        let retry = englishPresentation.describe(
            DiagnosticEvent(code: .retryScheduled, tNanos: 1, ms: 32_331)
        )
        #expect(retry.fields == [.init(key: "retry_delay", value: "32.331 seconds")])

        let oneSecond = englishPresentation.describe(
            DiagnosticEvent(code: .retryScheduled, tNanos: 1, ms: 1_000)
        )
        #expect(oneSecond.fields == [.init(key: "retry_delay", value: "1 second")])

        let twoSeconds = englishPresentation.describe(
            DiagnosticEvent(code: .retryScheduled, tNanos: 1, ms: 2_000)
        )
        #expect(twoSeconds.fields == [.init(key: "retry_delay", value: "2 seconds")])

        let subSecond = englishPresentation.describe(
            DiagnosticEvent(code: .retryScheduled, tNanos: 1, ms: 999)
        )
        #expect(subSecond.fields == [.init(key: "retry_delay", value: "999 ms")])

        let close = englishPresentation.describe(
            DiagnosticEvent(
                code: .transportCloseAttribution,
                tNanos: 1,
                ms: 7,
                a: 3,
                b: DiagnosticFailureKind.transportIdleTimedOut.rawValue,
                c: 9
            )
        )
        #expect(close.fields == [
            .init(key: "initiator", value: "Timed out"),
            .init(key: "failure", value: "Transport idle timed out"),
            .init(key: "application_error_code", value: "7"),
            .init(key: "session", value: "9"),
        ])
        let closeSummary = englishPresentation.summary(close)
        #expect(!closeSummary.contains("Session"))
        #expect(!closeSummary.contains("9"))
    }

    @Test func describesLifecycleAndReachability() {
        let phase = englishPresentation.describe(
            DiagnosticEvent(code: .appLifecycleChanged, tNanos: 1, a: DiagnosticAppLifecyclePhase.background.rawValue)
        )
        #expect(phase.fields == [.init(key: "phase", value: "Background")])

        let reachability = englishPresentation.describe(
            DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 0)
        )
        #expect(reachability.fields == [.init(key: "network", value: "Offline")])
    }

    @Test func unknownRawValuesFallBackToIntegers() {
        let described = englishPresentation.describe(
            DiagnosticEvent(code: .transportDialFailed, tNanos: 1, a: 999, b: 998)
        )
        #expect(described.fields == [
            .init(key: "transport", value: "Unknown transport (999)"),
            .init(key: "failure", value: "Unknown failure (998)"),
        ])
    }

    @Test func everyEventCodeHasAReadableTitle() {
        let expected: [DiagnosticEventCode: String] = [
            .connect: "Connection attempt started",
            .pairOk: "Pairing succeeded",
            .pairFail: "Pairing failed",
            .renderGridLag: "Render grid lagged",
            .livenessResubscribe: "Silent event stream resubscribed",
            .streamEnded: "Event stream ended",
            .inputSeqBehind: "Terminal input acknowledgements fell behind",
            .byteGap: "Terminal byte gap detected",
            .error: "Unclassified transport error",
            .pairUnreachable: "Pairing skipped while offline",
            .composerPresentedChanged: "Composer visibility changed",
            .composerInputTextChanged: "Composer draft changed",
            .composerViewAppear: "Composer appeared",
            .composerViewDisappear: "Composer disappeared",
            .composerFieldFocusChanged: "Composer focus changed",
            .composerActiveTransition: "Composer activation changed",
            .composerKeyboardToggleWhilePresented: "Keyboard toggled while composer was open",
            .transportDialStarted: "Transport dial started",
            .transportDialConnected: "Transport connected",
            .transportDialFailed: "Transport dial failed",
            .hostAuthenticated: "Host authenticated",
            .rpcReady: "RPC session ready",
            .recoveryStarted: "Connection recovery started",
            .recoverySucceeded: "Connection recovery succeeded",
            .recoveryFailed: "Connection recovery failed",
            .endpointStarting: "Iroh endpoint starting",
            .endpointActive: "Iroh endpoint active",
            .endpointStopped: "Iroh endpoint stopped",
            .endpointFailed: "Iroh endpoint failed",
            .relayPolicyRefreshStarted: "Relay policy refresh started",
            .relayPolicyRefreshSucceeded: "Relay policy refreshed",
            .relayPolicyRefreshFailed: "Relay policy refresh failed",
            .selectedPathChanged: "Selected network path changed",
            .sessionClosed: "Transport session closed",
            .routeUnavailable: "No usable transport route",
            .retryScheduled: "Retry scheduled",
            .discoveryStarted: "Iroh route discovery started",
            .discoverySucceeded: "Iroh route discovery succeeded",
            .discoveryFailed: "Iroh route discovery failed",
            .admissionSucceeded: "Client admitted",
            .admissionFailed: "Client admission failed",
            .hostAuthenticationFailed: "Host authentication failed",
            .rpcFailed: "RPC session failed",
            .transportSessionLifecycle: "Transport session state changed",
            .appLifecycleChanged: "App lifecycle changed",
            .reachabilityChanged: "Network reachability changed",
            .transportCloseAttribution: "Transport close attributed",
            .transportPathEvent: "Transport path changed",
            .browserStreamLifecycle: "Browser stream lifecycle",
            .browserInputReplayed: "Browser input replayed",
            .browserEditableFocus: "Browser editable focus",
            .browserPanelCreateResolved: "Browser panel create resolved",
            .simulatorStreamLifecycle: "Simulator stream state changed",
            .simulatorFrameLifecycle: "Simulator frame pipeline changed",
            .simulatorInputLifecycle: "Simulator input state changed",
            .simulatorCoordinateMapped: "Simulator touch coordinate mapped",
            .simulatorOwnershipChanged: "Simulator control ownership changed",
        ]

        #expect(Set(expected.keys) == Set(DiagnosticEventCode.allCases))
        for code in DiagnosticEventCode.allCases {
            #expect(
                englishPresentation.describe(
                    DiagnosticEvent(code: code, tNanos: 1)
                ).name == expected[code]
            )
        }
    }

    @Test func decodesEveryStructuredPayloadIntoSemanticFields() {
        let recovery = englishPresentation.describe(DiagnosticEvent(
            code: .recoveryStarted,
            tNanos: 1,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: 1
        ))
        #expect(recovery.fields == [
            .init(key: "transport", value: "Iroh"),
            .init(key: "trigger", value: "Network changed"),
        ])

        let endpoint = englishPresentation.describe(DiagnosticEvent(
            code: .endpointFailed,
            tNanos: 1,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.endpointUnavailable.rawValue
        ))
        #expect(endpoint.fields == [
            .init(key: "transport", value: "Iroh"),
            .init(key: "failure", value: "Iroh endpoint unavailable"),
        ])

        let session = englishPresentation.describe(DiagnosticEvent(
            code: .transportSessionLifecycle,
            tNanos: 1,
            a: DiagnosticSessionLifecycleKind.established.rawValue,
            b: Int(CmxTransportSessionPurpose.foregroundControl.rawValue),
            c: 12
        ))
        #expect(session.fields == [
            .init(key: "state", value: "Established"),
            .init(key: "purpose", value: "Foreground control"),
            .init(key: "session", value: "12"),
        ])

        let composer = englishPresentation.describe(DiagnosticEvent(
            code: .composerActiveTransition,
            tNanos: 1,
            ms: 300,
            a: 1,
            b: InputResponderIdentity.uiTextField.rawValue,
            c: 0
        ))
        #expect(composer.fields == [
            .init(key: "composer_active", value: "Yes"),
            .init(key: "first_responder", value: "Text field"),
            .init(key: "keyboard_height", value: "300 points"),
            .init(key: "terminal_input_focused", value: "No"),
        ])

        let input = englishPresentation.describe(DiagnosticEvent(
            code: .inputSeqBehind,
            tNanos: 1,
            surface: 7,
            a: 10,
            b: 20
        ))
        #expect(input.fields == [
            .init(key: "surface", value: "7"),
            .init(key: "local_sequence", value: "10"),
            .init(key: "remote_sequence", value: "20"),
        ])

        let browserLifecycle = englishPresentation.describe(DiagnosticEvent(
            code: .browserStreamLifecycle,
            tNanos: 1,
            a: 4,
            c: 987
        ))
        #expect(browserLifecycle.fields == [
            .init(key: "stage", value: "First frame delivered"),
            .init(key: "panel", value: "987"),
        ])

        let browserInput = englishPresentation.describe(DiagnosticEvent(
            code: .browserInputReplayed,
            tNanos: 1,
            a: 4,
            b: 1,
            c: 987
        ))
        #expect(browserInput.fields == [
            .init(key: "input", value: "Key suppressed"),
            .init(key: "count", value: "1"),
            .init(key: "panel", value: "987"),
        ])

        let browserFocus = englishPresentation.describe(DiagnosticEvent(
            code: .browserEditableFocus,
            tNanos: 1,
            a: 1,
            b: 2,
            c: 987
        ))
        #expect(browserFocus.fields == [
            .init(key: "editable_focused", value: "Yes"),
            .init(key: "outcome", value: "Already focused"),
            .init(key: "panel", value: "987"),
        ])

        let browserCreate = englishPresentation.describe(DiagnosticEvent(
            code: .browserPanelCreateResolved,
            tNanos: 1,
            a: 1,
            c: 987
        ))
        #expect(browserCreate.fields == [
            .init(key: "created", value: "Yes"),
            .init(key: "panel", value: "987"),
        ])

        let simulatorStream = englishPresentation.describe(DiagnosticEvent(
            code: .simulatorStreamLifecycle,
            tNanos: 1,
            surface: 19,
            a: DiagnosticSimulatorStreamLifecycle.started.rawValue,
            b: DiagnosticSimulatorOwnershipState.currentConnection.rawValue,
            c: 1
        ))
        #expect(simulatorStream.fields == [
            .init(key: "surface", value: "19"),
            .init(key: "state", value: "Started"),
            .init(key: "owner", value: "Current connection"),
            .init(key: "active_sessions", value: "1"),
        ])

        let simulatorFrame = englishPresentation.describe(DiagnosticEvent(
            code: .simulatorFrameLifecycle,
            tNanos: 1,
            surface: 19,
            a: DiagnosticSimulatorFrameLifecycle.cachedSent.rawValue,
            b: 42,
            c: 11_235
        ))
        #expect(simulatorFrame.fields == [
            .init(key: "surface", value: "19"),
            .init(key: "state", value: "Cached frame sent"),
            .init(key: "frame_sequence", value: "42"),
            .init(key: "payload_size", value: "11,235 bytes"),
        ])

        let simulatorInput = englishPresentation.describe(DiagnosticEvent(
            code: .simulatorInputLifecycle,
            tNanos: 1,
            surface: 19,
            a: DiagnosticSimulatorInputLifecycle.accepted.rawValue,
            b: DiagnosticSimulatorInputKind.hardwareButton.rawValue,
            c: DiagnosticSimulatorHardwareButtonKind.appSwitcher.rawValue
        ))
        #expect(simulatorInput.fields == [
            .init(key: "surface", value: "19"),
            .init(key: "state", value: "Accepted"),
            .init(key: "input", value: "Hardware button"),
            .init(key: "input_detail", value: "App Switcher"),
        ])

        let simulatorCoordinate = englishPresentation.describe(DiagnosticEvent(
            code: .simulatorCoordinateMapped,
            tNanos: 1,
            surface: 19,
            a: 1_234,
            b: 9_876,
            c: DiagnosticSimulatorCoordinateState.mapped.rawValue
        ))
        #expect(simulatorCoordinate.fields == [
            .init(key: "surface", value: "19"),
            .init(key: "x", value: "0.1234"),
            .init(key: "y", value: "0.9876"),
            .init(key: "mapping", value: "Mapped"),
        ])

        let simulatorOwnership = englishPresentation.describe(DiagnosticEvent(
            code: .simulatorOwnershipChanged,
            tNanos: 1,
            surface: 19,
            a: DiagnosticSimulatorOwnershipState.otherConnection.rawValue,
            b: DiagnosticSimulatorOwnershipState.currentConnection.rawValue
        ))
        #expect(simulatorOwnership.fields == [
            .init(key: "surface", value: "19"),
            .init(key: "owner", value: "Other connection"),
            .init(key: "previous_owner", value: "Current connection"),
        ])

        for described in [
            recovery, endpoint, session, composer, input, browserLifecycle,
            browserInput, browserFocus, browserCreate, simulatorStream,
            simulatorFrame, simulatorInput, simulatorCoordinate, simulatorOwnership,
        ] {
            #expect(!described.fields.contains { ["a", "b", "c", "ms"].contains($0.key) })
        }
    }

    @Test func extractsFailureAndTransportKinds() {
        let event = DiagnosticEvent(
            code: .endpointFailed,
            tNanos: 1,
            b: DiagnosticFailureKind.identityMismatch.rawValue
        )
        #expect(englishPresentation.failureKind(of: event) == .identityMismatch)
        #expect(englishPresentation.transportKind(of: event) == nil)

        let success = DiagnosticEvent(code: .rpcReady, tNanos: 1, b: 3)
        #expect(englishPresentation.failureKind(of: success) == nil)
    }

    @Test(.enabled(
        if: LocalizationTestSupport().hasCompiledLocalization(for: Locale(identifier: "ja")),
        "Command-line SwiftPM copies string catalogs without compiling locale resources"
    ))
    func presentsJapaneseReportCopy() {
        let presentation = DiagnosticEventPresentation(locale: Locale(identifier: "ja"))
        let event = DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 0)

        #expect(presentation.summary(event) == "ネットワーク到達性が変更されました（ネットワーク: オフライン）")
        let retry = presentation.describe(
            DiagnosticEvent(code: .retryScheduled, tNanos: 2, ms: 1_000)
        )
        #expect(retry.fields == [.init(key: "retry_delay", value: "1秒")])
    }
}
