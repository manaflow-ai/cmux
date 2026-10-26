import Darwin

/// The sanitizer runtime this process runs with: `scripts/reload.sh --config asan|tsan|ubsan` builds the
/// Release app with it, as Chromium's `is_asan` / `is_tsan` / `is_ubsan` release builds do
/// (`build/config/sanitizers/BUILD.gn`).
///
/// In such a build Chromium stays unloaded unless asked for: CEF's PartitionAlloc replaces the default
/// malloc zone and is not instrumented, so ASan and TSan then cover nothing or report false bad frees
/// (Chromium sets `use_partition_alloc_as_malloc=false` under ASan for the same reason). The early
/// delegating zone (``cmux_early_malloc_zone_registration()``) only exists for PartitionAlloc, so it is
/// skipped too. `CMUX_NEXT_SANITIZER_CHROMIUM=1` loads Chromium anyway, for a run the lab marks invalid.
nonisolated struct SanitizerRuntime: Equatable, Sendable {
    nonisolated enum Kind: String, CaseIterable, Sendable {
        case asan, tsan, ubsan

        /// A symbol only this sanitizer's runtime exports. ASan and TSan also carry the UBSan
        /// handlers, so ``SanitizerRuntime/detect(environment:exports:)`` asks in this order.
        var entrySymbol: String {
            switch self {
            case .asan: "__asan_init"
            case .tsan: "__tsan_init"
            case .ubsan: "__ubsan_handle_builtin_unreachable"
            }
        }
    }

    /// The environment variable that loads Chromium in a sanitizer build.
    static let chromiumOverrideKey = "CMUX_NEXT_SANITIZER_CHROMIUM"

    /// The sanitizer linked into this process; nil in every shipped build.
    let kind: Kind?
    /// True when the launch asked for Chromium despite the sanitizer.
    let chromiumRequested: Bool

    /// Whether this process may load Chromium (and so needs the early delegating malloc zone).
    var loadsChromium: Bool { kind == nil || chromiumRequested }

    /// Finds the runtime by its exported entry symbol.
    ///
    /// - Parameters:
    ///   - environment: The launch environment (``chromiumOverrideKey``).
    ///   - exports: Whether the process exports a symbol; tests pass their own.
    static func detect(environment: [String: String],
                       exports: (String) -> Bool = SanitizerRuntime.processExports) -> SanitizerRuntime {
        let kind = Kind.allCases.first { exports($0.entrySymbol) }
        return SanitizerRuntime(kind: kind, chromiumRequested: kind != nil && environment[chromiumOverrideKey] == "1")
    }

    /// `dlsym(RTLD_DEFAULT, name)`: the loaded images export `name`.
    static func processExports(_ name: String) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }
}
