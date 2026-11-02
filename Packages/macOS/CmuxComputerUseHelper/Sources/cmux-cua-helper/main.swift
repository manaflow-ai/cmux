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

// Machine-join consent and app approvals come only from the cmux app over
// the host consent socket, whose peer is checked by audit token
// (HostConsentServer). The mode comes from the environment the app set.
let environment = ProcessInfo.processInfo.environment
let stack = ComputerUseStack(
    libraryPath: (Bundle.main.privateFrameworksPath ?? "") + "/libcua_driver_sdk.dylib",
    environment: environment,
    allowedTargetBundleIDs: environment["CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS"] ?? "",
    hostBundleID: environment["CMUX_CUA_HOST_BUNDLE_ID"],
    log: { FileHandle.standardError.write(Data("cmux-cua-helper: \($0)\n".utf8)) }
)
let controller = stack.controller()
controller.start()
CFRunLoopRun()
