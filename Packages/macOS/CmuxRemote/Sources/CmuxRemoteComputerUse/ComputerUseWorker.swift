// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxCuaHelperCore
import Darwin
import Foundation

/// The Computer Use worker (`cmux-remote worker computer-use`): the helper v2
/// (docs/computer-use.md) as a child of cmux Remote, so macOS checks its
/// Accessibility and Screen Recording as cmux Remote's. Its stdin and stdout
/// are the app's channel through the host: the same control lines the app
/// sent the helper's stdin, and EOF (the app's channel closed) stops it.
/// Upstream Cua Driver runs in process, loaded from this bundle's Frameworks.
public struct ComputerUseWorker: Sendable {
    public init() {}

    /// Never returns.
    public func run(bundleIdentifier: String) -> Never {
        // Before any thread starts and before the driver loads.
        HelperEnvironment(helperBundleID: bundleIdentifier).apply()
        let consent = HostConsentChannel()
        let tools: any ToolInvoking
        let libraryPath = (Bundle.main.privateFrameworksPath ?? "") + "/libcua_driver_sdk.dylib"
        do {
            tools = try CuaDriverRuntime(
                libraryPath: libraryPath,
                allowedTargetBundleIDs: ProcessInfo.processInfo.environment["CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS"] ?? "",
                hostBundleID: bundleIdentifier,
                gate: ConsentGate(authority: consent)
            )
        } catch {
            FileHandle.standardError.write(Data("cmux-remote computer-use: \(error)\n".utf8))
            tools = UnavailableTools(reason: String(describing: error))
        }
        let controller = HelperController(tools: tools, consent: consent)
        controller.start()
        CFRunLoopRun()
        exit(0)
    }
}
