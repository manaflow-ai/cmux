internal import Foundation

#if DEBUG
/// Whether the release-lane version gate must also evaluate development-tag
/// Macs, which it otherwise never does (development builds only admit
/// development-tag Macs, rebuilt from source).
///
/// This is the dogfood switch for the gate: launch the tagged Mac with
/// `CMUX_DEBUG_MOBILE_APP_VERSION=<old version>` and the phone/simulator
/// with `CMUX_DEBUG_FORCE_MAC_COMPAT=1` (or the launch argument
/// `-CMUXDebugForceMacCompat YES`); the gate then evaluates the dev Mac with
/// its channel derived from the reported version grammar.
func mobileMacCompatDebugOverrideForcesEvaluation(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard
) -> Bool {
    environment["CMUX_DEBUG_FORCE_MAC_COMPAT"] == "1"
        || defaults.bool(forKey: "CMUXDebugForceMacCompat")
}
#endif
