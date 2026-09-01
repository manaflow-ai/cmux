import Testing
@testable import CmuxMobileSupport

@Suite struct UITestConfigTests {
    @Test func explicitDisableWinsOverTestHost() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration",
        ]
        #if DEBUG
        #expect(UITestConfig.mockDataEnabled(from: env) == false)
        #else
        #expect(UITestConfig.mockDataEnabled(from: env) == false)
        #endif
    }

    @Test func explicitEnableTurnsOnMockData() {
        let env = ["CMUX_UITEST_MOCK_DATA": "1"]
        #if DEBUG
        #expect(UITestConfig.mockDataEnabled(from: env) == true)
        #else
        #expect(UITestConfig.mockDataEnabled(from: env) == false)
        #endif
    }

    @Test func testHostPresenceEnablesMockDataInDebug() {
        let env = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        #if DEBUG
        #expect(UITestConfig.mockDataEnabled(from: env) == true)
        #else
        #expect(UITestConfig.mockDataEnabled(from: env) == false)
        #endif
    }

    @Test func emptyEnvironmentDisablesMockData() {
        #expect(UITestConfig.mockDataEnabled(from: [:]) == false)
    }

    @Test func valueReturnsTrimmedNonEmptyWhenMockEnabled() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_ADD_DEVICE_NAME": "  Work Mac  ",
        ]
        #if DEBUG
        #expect(UITestConfig.value(for: "CMUX_UITEST_ADD_DEVICE_NAME", env: env) == "Work Mac")
        #else
        #expect(UITestConfig.value(for: "CMUX_UITEST_ADD_DEVICE_NAME", env: env) == nil)
        #endif
    }

    @Test func valueIsNilWhenMockDisabled() {
        let env = ["CMUX_UITEST_ADD_DEVICE_NAME": "Work Mac"]
        #expect(UITestConfig.value(for: "CMUX_UITEST_ADD_DEVICE_NAME", env: env) == nil)
    }

    @Test func valueIsNilWhenBlank() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_ADD_DEVICE_HOST": "   ",
        ]
        #expect(UITestConfig.value(for: "CMUX_UITEST_ADD_DEVICE_HOST", env: env) == nil)
    }

    #if DEBUG
    @Test(arguments: ["eligible", "ineligible"])
    func autoConnectMigrationFixtureRequiresMockDataAndParsesEligibility(_ raw: String) {
        let configuration = AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": raw,
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "  migration-run  ",
        ])

        #expect(configuration?.eligibility.rawValue == raw)
        #expect(configuration?.identifier == "migration-run")
        #expect(configuration?.presentsShellSettingsBeforeMigration == false)
        #expect(configuration?.initialModalHost == nil)
        #expect(configuration?.readinessGate == nil)
        #expect(configuration?.persistedConnectionMethod == nil)
        #expect(configuration?.legacyResolution == nil)
        #expect(configuration?.showsLayoutProbe == false)
        #expect(
            configuration?.defaultsSuiteName
                == "dev.cmux.uitest.autoConnectMigration.migration-run"
        )
    }

    @Test func autoConnectMigrationFixtureParsesPersistedUpgradeState() {
        let configuration = AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "migration-run",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_PERSISTED_METHOD": " automatic ",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_V1_RESOLUTION": " ineligible ",
        ])

        #expect(configuration?.persistedConnectionMethod == .automatic)
        #expect(configuration?.legacyResolution == .ineligible)
    }

    @Test func autoConnectMigrationFixtureRequiresExplicitLayoutProbeOptIn() {
        let baseEnvironment = [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "migration-run",
        ]
        var enabledEnvironment = baseEnvironment
        enabledEnvironment["CMUX_UITEST_AUTOCONNECT_MIGRATION_LAYOUT_PROBES"] = " 1 "
        var disabledEnvironment = baseEnvironment
        disabledEnvironment["CMUX_UITEST_AUTOCONNECT_MIGRATION_LAYOUT_PROBES"] = "true"

        #expect(
            AutoConnectMigrationUITestConfiguration(environment: enabledEnvironment)?
                .showsLayoutProbe == true
        )
        #expect(
            AutoConnectMigrationUITestConfiguration(environment: disabledEnvironment)?
                .showsLayoutProbe == false
        )
    }

    @Test func autoConnectMigrationFixtureParsesInitialSettingsDeferralBehindMockGate() {
        let configuration = AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "migration-run",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_SETTINGS": " 1 ",
        ])

        #expect(configuration?.presentsShellSettingsBeforeMigration == true)
        #expect(AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "0",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "migration-run",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_SETTINGS": "1",
        ]) == nil)
    }

    @Test func autoConnectMigrationFixtureParsesRealInitialModalHosts() throws {
        let cases: [(String, AutoConnectMigrationUITestConfiguration.InitialModalHost)] = [
            ("root-pairing", .rootPairing),
            ("workspace-list-device-tree", .workspaceListDeviceTree),
            ("workspace-detail-terminal-text", .workspaceDetailTerminalText),
        ]

        for (rawValue, expected) in cases {
            let configuration = try #require(AutoConnectMigrationUITestConfiguration(
                environment: [
                    "CMUX_UITEST_MOCK_DATA": "1",
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "migration-run",
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_MODAL_HOST": rawValue,
                ]
            ))
            #expect(configuration.initialModalHost == expected)
        }
    }

    @Test func autoConnectMigrationFixtureParsesReadinessGates() throws {
        let cases: [(String, AutoConnectMigrationUITestConfiguration.ReadinessGate)] = [
            ("authentication-restoring", .authenticationRestoring),
            ("scene-inactive", .sceneInactive),
            ("explicit-attach-route", .explicitAttachRoute),
        ]

        for (rawValue, expected) in cases {
            let configuration = try #require(AutoConnectMigrationUITestConfiguration(
                environment: [
                    "CMUX_UITEST_MOCK_DATA": "1",
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "migration-run",
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION_READINESS_GATE": rawValue,
                ]
            ))
            #expect(configuration.readinessGate == expected)
        }
    }

    @Test func autoConnectMigrationFixtureRejectsUnsafeOrIncompleteInputs() {
        #expect(AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "0",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "run",
        ]) == nil)
        #expect(AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "unknown",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "run",
        ]) == nil)
        #expect(AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "   ",
        ]) == nil)
        #expect(AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "run",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_MODAL_HOST": "unknown",
        ]) == nil)
        #expect(AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "run",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_READINESS_GATE": "unknown",
        ]) == nil)
        #expect(AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "run",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_PERSISTED_METHOD": "invalid",
        ]) == nil)
        #expect(AutoConnectMigrationUITestConfiguration(environment: [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": "run",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_V1_RESOLUTION": "invalid",
        ]) == nil)
    }
    #endif

    // MARK: - dogfoodAttachURL (NOT mock-gated)

    /// The core P2 fix: the dogfood attach URL must be returned even when mock data
    /// is off (the real-backend dev-launch path), so iOS auto-pair actually fires.
    @Test func dogfoodAttachURLReturnedWithMockDisabled() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "CMUX_DOGFOOD_ATTACH_URL": "cmux-ios://attach?v=1&payload=abc",
        ]
        #if DEBUG
        #expect(UITestConfig.dogfoodAttachURL(from: env) == "cmux-ios://attach?v=1&payload=abc")
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: env) == nil)
        #endif
    }

    /// Regression guard: with mock off, the legacy mock-gated `attachURL`
    /// (`CMUX_UITEST_ATTACH_URL`) stays nil, which is exactly why the dedicated
    /// dogfood accessor is required for the real-backend auto-pair path.
    @Test func legacyAttachURLStaysNilWithMockDisabledButDogfoodDoesNot() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "CMUX_UITEST_ATTACH_URL": "cmux-ios://attach?v=1&payload=legacy",
            "CMUX_DOGFOOD_ATTACH_URL": "cmux-ios://attach?v=1&payload=dogfood",
        ]
        #expect(UITestConfig.value(for: "CMUX_UITEST_ATTACH_URL", env: env) == nil)
        #if DEBUG
        #expect(UITestConfig.dogfoodAttachURL(from: env) == "cmux-ios://attach?v=1&payload=dogfood")
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: env) == nil)
        #endif
    }

    @Test func dogfoodAttachURLIsTrimmed() {
        let env = ["CMUX_DOGFOOD_ATTACH_URL": "  cmux-ios://attach?v=1&payload=zzz  "]
        #if DEBUG
        #expect(UITestConfig.dogfoodAttachURL(from: env) == "cmux-ios://attach?v=1&payload=zzz")
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: env) == nil)
        #endif
    }

    @Test func dogfoodAttachURLIsNilWhenAbsent() {
        #expect(UITestConfig.dogfoodAttachURL(from: [:]) == nil)
    }

    @Test func dogfoodAttachURLIsNilWhenBlank() {
        let env = ["CMUX_DOGFOOD_ATTACH_URL": "   "]
        #expect(UITestConfig.dogfoodAttachURL(from: env) == nil)
    }

    @Test func workspaceDetailRefreshingTerminalMenuFlagIsDebugOnly() {
        let env = ["CMUX_UITEST_WORKSPACE_DETAIL_REFRESHING_TERMINAL_MENU": "1"]
        #if DEBUG
        #expect(UITestConfig.workspaceDetailRefreshingTerminalMenuPreviewEnabled(from: env) == true)
        #else
        #expect(UITestConfig.workspaceDetailRefreshingTerminalMenuPreviewEnabled(from: env) == false)
        #endif
    }

    @Test func workspaceDetailRefreshingTerminalMenuFlagRequiresOne() {
        #expect(UITestConfig.workspaceDetailRefreshingTerminalMenuPreviewEnabled(from: [:]) == false)
        #expect(UITestConfig.workspaceDetailRefreshingTerminalMenuPreviewEnabled(
            from: ["CMUX_UITEST_WORKSPACE_DETAIL_REFRESHING_TERMINAL_MENU": "0"]
        ) == false)
    }

    @Test(arguments: ["1", "diff", "empty", "states"])
    func changesPreviewAcceptsSupportedModes(_ mode: String) {
        #if DEBUG
        #expect(UITestConfig.changesPreviewMode(
            from: ["CMUX_UITEST_CHANGES_PREVIEW": mode]
        ) == mode)
        #else
        #expect(UITestConfig.changesPreviewMode(
            from: ["CMUX_UITEST_CHANGES_PREVIEW": mode]
        ) == nil)
        #endif
    }

    @Test func changesPreviewRejectsUnknownModeAndReadsArguments() {
        #expect(UITestConfig.changesPreviewMode(
            from: ["CMUX_UITEST_CHANGES_PREVIEW": "unknown"]
        ) == nil)
        #if DEBUG
        #expect(UITestConfig.changesPreviewMode(
            from: [:],
            arguments: ["CMUX_UITEST_CHANGES_PREVIEW=diff"]
        ) == "diff")
        #else
        #expect(UITestConfig.changesPreviewMode(
            from: [:],
            arguments: ["CMUX_UITEST_CHANGES_PREVIEW=diff"]
        ) == nil)
        #endif
    }

    @Test func pushReadinessPreviewUsesExplicitInputsWithEnvironmentPrecedence() {
        #if DEBUG
        #expect(UITestConfig.pushReadinessPreviewState(
            from: ["CMUX_UITEST_PUSH_READINESS_PREVIEW": "healthy"],
            arguments: ["CMUX_UITEST_PUSH_READINESS_PREVIEW=unavailable"]
        ) == "healthy")
        #expect(UITestConfig.pushReadinessPreviewState(
            from: [:],
            arguments: ["CMUX_UITEST_PUSH_READINESS_PREVIEW=permission-denied"]
        ) == "permission-denied")
        #else
        #expect(UITestConfig.pushReadinessPreviewState(
            from: ["CMUX_UITEST_PUSH_READINESS_PREVIEW": "healthy"]
        ) == nil)
        #endif
    }

    @Test func notificationFeedPreviewFlagIsDebugOnly() {
        let env = ["CMUX_UITEST_NOTIFICATION_FEED_PREVIEW": "1"]
        #if DEBUG
        #expect(UITestConfig.notificationFeedPreviewEnabled(from: env) == true)
        #else
        #expect(UITestConfig.notificationFeedPreviewEnabled(from: env) == false)
        #endif
    }

    @Test func notificationFeedPreviewFlagRequiresOne() {
        #expect(UITestConfig.notificationFeedPreviewEnabled(from: [:]) == false)
        #expect(UITestConfig.notificationFeedPreviewEnabled(
            from: ["CMUX_UITEST_NOTIFICATION_FEED_PREVIEW": "0"]
        ) == false)
    }

    @Test func taskComposerPreviewFlagIsDebugOnly() {
        let env = ["CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1"]
        #if DEBUG
        #expect(UITestConfig.taskComposerPreviewEnabled(from: env))
        #else
        #expect(!UITestConfig.taskComposerPreviewEnabled(from: env))
        #endif
    }

    @Test func taskComposerPreviewFlagRequiresOne() {
        #expect(!UITestConfig.taskComposerPreviewEnabled(from: [:]))
        #expect(!UITestConfig.taskComposerPreviewEnabled(from: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "0",
        ]))
    }

    #if DEBUG
    @Test func pairingScannerPreviewFlagCanBeEnabled() {
        let env = ["CMUX_UITEST_SCANNER_PREVIEW": "1"]
        #expect(UITestEnvironmentConfig(environment: env).pairingScannerPreviewEnabled == true)
    }

    @Test func onboardingPreviewFlagCanBeEnabled() {
        let env = ["CMUX_UITEST_ONBOARDING_PREVIEW": "1"]
        #expect(UITestEnvironmentConfig(environment: env).onboardingPreviewEnabled == true)
    }

    @Test func onboardingPreviewFlagRequiresOne() {
        #expect(UITestEnvironmentConfig(environment: [:]).onboardingPreviewEnabled == false)
        #expect(UITestEnvironmentConfig(
            environment: ["CMUX_UITEST_ONBOARDING_PREVIEW": "0"]
        ).onboardingPreviewEnabled == false)
    }

    @Test func onboardingConnectionFallbackFlagCanBeEnabled() {
        let env = ["CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK": "1"]
        #expect(UITestEnvironmentConfig(environment: env).onboardingConnectionFallbackEnabled == true)
    }

    @Test func onboardingConnectionFallbackFlagRequiresOne() {
        #expect(UITestEnvironmentConfig(environment: [:]).onboardingConnectionFallbackEnabled == false)
        #expect(UITestEnvironmentConfig(
            environment: ["CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK": "0"]
        ).onboardingConnectionFallbackEnabled == false)
    }

    @Test func pairingScannerPreviewFlagRequiresOne() {
        #expect(UITestEnvironmentConfig(environment: [:]).pairingScannerPreviewEnabled == false)
        #expect(UITestEnvironmentConfig(
            environment: ["CMUX_UITEST_SCANNER_PREVIEW": "0"]
        ).pairingScannerPreviewEnabled == false)
    }
    #endif
}
