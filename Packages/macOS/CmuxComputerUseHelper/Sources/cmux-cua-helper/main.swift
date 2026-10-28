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

let tools: any ToolInvoking
let libraryPath = (Bundle.main.privateFrameworksPath ?? "") + "/libcua_driver_sdk.dylib"
do {
    tools = try CuaDriverRuntime(libraryPath: libraryPath)
} catch {
    FileHandle.standardError.write(Data("cmux-cua-helper: \(error)\n".utf8))
    tools = UnavailableTools(reason: String(describing: error))
}

let controller = HelperController(tools: tools)
controller.start()
CFRunLoopRun()
