import os

/// Writes one launch line in a bench build (`reload.sh --config bench`: Release optimization with
/// `-DDEBUG -DCMUX_BENCH_HOOKS`), and nothing in any other build.
///
/// The line's text is also the marker `scripts/cmux-next/check-no-bench-hooks.sh` looks for in the
/// main executable: the release and nightly pipelines refuse an app that has it, and the bench build
/// requires it (proof that its flags reached this module).
func announceBenchHooksBuild() {
    #if CMUX_BENCH_HOOKS
    Logger(subsystem: "com.cmuxterm.app.next", category: "launch")
        .notice("CMUX_BENCH_HOOKS_BUILD: debug control commands are compiled into an optimized build; never ship it")
    #endif
}
