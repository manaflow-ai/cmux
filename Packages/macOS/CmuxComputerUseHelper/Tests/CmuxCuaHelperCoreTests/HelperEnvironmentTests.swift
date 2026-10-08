// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import Testing

@Suite(.serialized) struct HelperEnvironmentTests {
    @Test func requiredValuesAreExact() {
        #expect(HelperEnvironment(helperBundleID: "com.cmuxterm.cua.dev").required == [
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "CUA_TELEMETRY_ENABLED": "false",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
            "CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS": "100",
            "CUA_DRIVER_HOST_BUNDLE_ID": "com.cmuxterm.cua.dev",
        ])
    }

    @Test func applyOverridesWhatTheLauncherPassed() {
        setenv("CUA_DRIVER_RS_TELEMETRY_ENABLED", "1", 1)
        setenv("CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS", "1000", 1)
        HelperEnvironment(helperBundleID: "com.cmuxterm.cua.dev").apply()
        #expect(getenv("CUA_DRIVER_RS_TELEMETRY_ENABLED").map { String(cString: $0) } == "0")
        #expect(getenv("CUA_DRIVER_RS_UPDATE_CHECK").map { String(cString: $0) } == "false")
        #expect(getenv("CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS").map { String(cString: $0) } == "100")
    }
}
