@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task 032 of plans/cmux-next/chrome-parity/p01-process.md: in host mode cmux installs no
/// focus_request_fn (its answer is synchronous and would cross the wire); the host's shim grants a
/// focus request only for a page cmux marked embedder-active (CEFShim/src/embedder_focus_policy.h,
/// scripts/cmux-next/test-shim-embedder-focus-cpp.sh). In process cmux's handler still refuses
/// Chromium's own requests.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFFocusRequestPolicyTests {
    @Test func inProcessInstallsCmuxsFocusHandler() throws {
        let shim = try Self.shim()
        let runtime = Self.runtime(shim, hostMode: false)

        runtime.installFocusRequestPolicy(shim)

        #expect(FocusHandlerSpy.installs == [true])
    }

    @Test func hostModeInstallsNoFocusHandler() throws {
        let shim = try Self.shim()
        let runtime = Self.runtime(shim, hostMode: true)

        runtime.installFocusRequestPolicy(shim)

        #expect(FocusHandlerSpy.installs.isEmpty, "the host's shim decides by embedder-active")
    }

    // MARK: Fixtures

    private static func shim() throws -> CEFShimLibrary {
        FocusHandlerSpy.installs = []
        return try CEFShimLibrary.resolving(FocusHandlerSpy.symbol)
    }

    /// A runtime that outlives the test, as CEFTabHostFocusTests' (work it schedules may read it).
    private static func runtime(_ shim: CEFShimLibrary, hostMode: Bool) -> CEFRuntime {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cef-focus-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root))
        if hostMode { runtime.hostStart = CEFHostStart(supervisor: FocusPolicyNoHost(), clock: ContinuousClock()) }
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }
}

/// Never attaches: the test only reads whether the runtime is in host mode.
@MainActor private final class FocusPolicyNoHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// Stand-in shim functions: `set_focus_request_handler` records whether it got a handler, every
/// other function does nothing and returns 0.
private nonisolated enum FocusHandlerSpy {
    nonisolated(unsafe) static var installs: [Bool] = []

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let setHandler: @convention(c) (CEFShimLibrary.FocusRequestFn?) -> Void = { handler in
            FocusHandlerSpy.installs.append(handler != nil)
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_set_focus_request_handler": unsafeBitCast(setHandler, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
