import Darwin

/// The sanitizer runtime this process runs with: `scripts/reload.sh --config asan|tsan|ubsan` builds the
/// Release app with it, as Chromium's `is_asan` / `is_tsan` / `is_ubsan` release builds do
/// (`build/config/sanitizers/BUILD.gn`).
///
/// In such a build Chromium stays unloaded unless asked for: CEF's PartitionAlloc replaces the default
/// malloc zone and is not instrumented, so ASan and TSan then cover nothing or report false bad frees
/// (Chromium sets `use_partition_alloc_as_malloc=false` under ASan for the same reason). The early
/// delegating malloc zone (CmuxNextMallocZone) only exists for PartitionAlloc, so it is skipped too.
/// `CMUX_NEXT_SANITIZER_CHROMIUM=1` loads Chromium anyway, for a run the lab marks invalid.
public struct SanitizerRuntime: Equatable, Sendable {
    /// A sanitizer `reload.sh --config` can build.
    public enum Kind: String, CaseIterable, Sendable {
        case asan, tsan, ubsan

        /// A symbol only this sanitizer's runtime exports. ASan and TSan also carry the UBSan
        /// handlers, so ``SanitizerRuntime/detect(environment:exports:)`` asks in this order.
        public var entrySymbol: String {
            switch self {
            case .asan: "__asan_init"
            case .tsan: "__tsan_init"
            case .ubsan: "__ubsan_handle_builtin_unreachable"
            }
        }
    }

    /// The environment variable that loads Chromium in a sanitizer build.
    public static let chromiumOverrideKey = "CMUX_NEXT_SANITIZER_CHROMIUM"

    /// The sanitizer linked into this process; nil in every shipped build.
    public let kind: Kind?
    /// True when the launch asked for Chromium despite the sanitizer.
    public let chromiumRequested: Bool

    /// Creates a runtime description; ``detect(environment:exports:)`` reads the process's.
    public init(kind: Kind?, chromiumRequested: Bool) {
        self.kind = kind
        self.chromiumRequested = chromiumRequested
    }

    /// Whether this process may load Chromium (and so needs the early delegating malloc zone).
    public var loadsChromium: Bool { kind == nil || chromiumRequested }

    /// Finds the runtime by its exported entry symbol.
    ///
    /// - Parameters:
    ///   - environment: The launch environment (``chromiumOverrideKey``).
    ///   - exports: Whether the process exports a symbol; tests pass their own.
    public static func detect(environment: [String: String],
                              exports: (String) -> Bool = SanitizerRuntime.processExports) -> SanitizerRuntime {
        let kind = Kind.allCases.first { exports($0.entrySymbol) }
        return SanitizerRuntime(kind: kind, chromiumRequested: kind != nil && environment[chromiumOverrideKey] == "1")
    }

    /// `dlsym(RTLD_DEFAULT, name)`: the loaded images export `name`.
    public static func processExports(_ name: String) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }
}
