// SPDX-License-Identifier: GPL-3.0-or-later
// cmux Computer Use helper v2. The cmux app starts this executable (inside
// "cmux Computer Use (dev).app" in DEV builds) with macOS responsibility
// disclaimed, so Accessibility and Screen Recording belong to the helper,
// never to cmux or its shells. Upstream Cua Driver runs in process.
import ApplicationServices
import CmuxCuaHelperCore
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)
let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.cua.dev"
let insideHelperBundle = Bundle.main.bundleIdentifier?.hasPrefix("com.cmuxterm.cua") == true
// Before any thread starts and before the driver loads.
HelperEnvironment(helperBundleID: bundleID).apply()

// Put the helper in the Accessibility list once per helper version, so the
// user can switch it on (macOS shows its own dialog; nothing else prompts).
if insideHelperBundle, !AXIsProcessTrusted() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let key = "accessibilityPromptedVersion"
    if UserDefaults.standard.string(forKey: key) != version {
        UserDefaults.standard.set(version, forKey: key)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

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
