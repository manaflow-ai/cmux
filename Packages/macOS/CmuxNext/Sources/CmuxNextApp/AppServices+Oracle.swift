import CmuxNextCompat
import CmuxNextControl
import CmuxNextSettings

// The oracle's app side (plans/cmux-next/chrome-parity/p15-oracle.md section 3C): values built here,
// in the composition root, and `debug.oracle.*` methods registered only in DEBUG and bench builds,
// so the router refuses them in Release by name.
extension AppServices {
    /// The hit a guarded site of refactor switch `key` holds next to its frozen arm: counted into
    /// ``switchHits`` in DEBUG and bench builds, counting nothing in Release.
    func switchHit(_ key: RefactorSwitchKey, site: StaticString) -> RefactorSwitchHit {
        #if DEBUG || CMUX_BENCH_HOOKS
        switchHits.hit(key, site: site)
        #else
        RefactorSwitchHit(key: key)
        #endif
    }

    /// `debug.oracle.switch_hits {"reset": true?}`: each switch's hits per arm and per site
    /// (``SwitchHits/report(reset:)``); `reset` starts the counts at 0 after reading them.
    func registerOracleSwitchHits(on router: ControlRouter?) {
        #if DEBUG || CMUX_BENCH_HOOKS
        router?.register([
            .mainActor("debug.oracle.switch_hits") { [weak self] call in
                guard let self else { return .value(.null) }
                return .value(switchHits.report(reset: call.params["reset"]?.boolValue == true))
            },
        ])
        #endif
    }
}
