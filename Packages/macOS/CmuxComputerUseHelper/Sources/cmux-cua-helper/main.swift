// SPDX-License-Identifier: GPL-3.0-or-later
// cmux Computer Use helper v2. The cmux app starts this executable (inside
// "cmux Computer Use (dev).app" in DEV builds) with macOS responsibility
// disclaimed, so Accessibility and Screen Recording belong to the helper,
// never to cmux or its shells. Upstream Cua Driver runs in process.
import CmuxCuaHelperCore
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)
let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.cua.dev"
// Before any thread starts and before the driver loads.
HelperEnvironment(helperBundleID: bundleID).apply()

// Starting (including after an update) never asks for a grant. The app's
// Computer Use setup buttons request each permission over the control pipe.

// Machine-join consent comes only from the cmux app over the host consent
// socket, whose peer is checked by audit token (HostConsentServer).
let consent = HostConsentChannel()
let tools: any ToolInvoking
let libraryPath = (Bundle.main.privateFrameworksPath ?? "") + "/libcua_driver_sdk.dylib"
do {
    tools = try CuaDriverRuntime(
        libraryPath: libraryPath,
        allowedTargetBundleIDs: ProcessInfo.processInfo.environment["CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS"] ?? "",
        hostBundleID: ProcessInfo.processInfo.environment["CMUX_CUA_HOST_BUNDLE_ID"],
        gate: ConsentGate(authority: consent)
    )
} catch {
    FileHandle.standardError.write(Data("cmux-cua-helper: \(error)\n".utf8))
    tools = UnavailableTools(reason: String(describing: error))
}

let controller = HelperController(tools: tools, consent: consent)
controller.start()
CFRunLoopRun()
