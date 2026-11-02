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
        // The mode comes from the environment the host set (docs/computer-use-approvals.md, "Modes").
        let environment = ProcessInfo.processInfo.environment
        let stack = ComputerUseStack(
            libraryPath: (Bundle.main.privateFrameworksPath ?? "") + "/libcua_driver_sdk.dylib",
            environment: environment,
            allowedTargetBundleIDs: environment["CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS"] ?? "",
            hostBundleID: bundleIdentifier,
            log: { FileHandle.standardError.write(Data("cmux-remote computer-use: \($0)\n".utf8)) }
        )
        let controller = stack.controller()
        controller.start()
        CFRunLoopRun()
        exit(0)
    }
}
