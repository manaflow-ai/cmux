struct MacSentryStartupPolicy {
    let telemetryEnabled: Bool
    let isRunningUnderXCTest: Bool
    let allowUnderXCTest: Bool

    var shouldStart: Bool {
        telemetryEnabled && (!isRunningUnderXCTest || allowUnderXCTest)
    }
}
