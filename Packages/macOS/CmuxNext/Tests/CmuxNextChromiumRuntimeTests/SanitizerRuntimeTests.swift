import CmuxNextChromiumRuntime
import Testing

/// A sanitizer app (`reload.sh --config asan|tsan|ubsan`) keeps Chromium and the early malloc zone off
/// unless its launch asks for Chromium.
struct SanitizerRuntimeTests {
    private func runtime(exporting symbols: Set<String>, environment: [String: String] = [:]) -> SanitizerRuntime {
        SanitizerRuntime.detect(environment: environment, exports: { symbols.contains($0) })
    }

    @Test func aShippedBuildHasNoSanitizerAndLoadsChromium() {
        let plain = runtime(exporting: [], environment: [SanitizerRuntime.chromiumOverrideKey: "1"])
        #expect(plain == SanitizerRuntime(kind: nil, chromiumRequested: false))
        #expect(plain.loadsChromium)
    }

    @Test func eachRuntimeIsFoundByItsOwnEntrySymbol() {
        // ASan and TSan also export the UBSan handlers.
        let ubsanHandler = SanitizerRuntime.Kind.ubsan.entrySymbol
        #expect(runtime(exporting: ["__asan_init", ubsanHandler]).kind == .asan)
        #expect(runtime(exporting: ["__tsan_init", ubsanHandler]).kind == .tsan)
        #expect(runtime(exporting: [ubsanHandler]).kind == .ubsan)
    }

    @Test func aSanitizerBuildKeepsChromiumOffUnlessTheLaunchAsks() {
        #expect(!runtime(exporting: ["__asan_init"]).loadsChromium)
        #expect(!runtime(exporting: ["__asan_init"], environment: [SanitizerRuntime.chromiumOverrideKey: "0"]).loadsChromium)
        let asked = runtime(exporting: ["__tsan_init"], environment: [SanitizerRuntime.chromiumOverrideKey: "1"])
        #expect(asked.chromiumRequested)
        #expect(asked.loadsChromium)
    }
}
