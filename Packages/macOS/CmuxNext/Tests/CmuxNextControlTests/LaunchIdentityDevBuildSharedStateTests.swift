import CmuxNextCompat
@testable import CmuxNextControl
import Foundation
import Testing

/// Another build's `cmux vm` config, MCP tool lists, mux plugins, classic folder and settings defaults, inherited
/// from its terminal, never reach this build's children: a launch from there strips each of them.
@Suite struct LaunchIdentityDevBuildSharedStateTests {
    @Test func anotherBuildsSharedStateVariablesAreStripped() {
        let inherited = ["CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.other",
                         "CMUX_VM_DEFAULT_CONFIG": "/o/vm.json", "CMUX_NEXT_MCP_UPSTREAMS_DIR": "/o/mcp",
                         "CMUX_NEXT_MUX_PLUGINS_DIR": "/o/plugins", "CMUX_NEXT_CLASSIC_IMPORT_DIR": "/o/classic",
                         "CMUX_NEXT_SETTINGS_BUILD_DEFAULTS": #"{"mobile.allowIPhoneConnections":true}"#]
        let stripped = Set(LaunchIdentity.inheritedKeys(processEnvironment: inherited, bundledEnvironment: [:]))
        for key in inherited.keys {
            #expect(stripped.contains(key), "\(key) from another build's terminal survived the launch")
        }
    }
}
