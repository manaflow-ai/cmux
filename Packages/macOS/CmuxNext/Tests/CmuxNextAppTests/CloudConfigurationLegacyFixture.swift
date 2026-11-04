import CmuxNextCloud
import Foundation

// Legacy unit fixtures exercise clients in isolation. They use synthetic
// origins through the runtime factory; production selection remains in Rust.
extension CloudConfiguration {
    static func resolve(bundleID: String?, bundled: [String: String], process: [String: String], isDebugBuild: Bool,
                        devAccount: DevAccount = .staging) -> CloudConfiguration {
        let value = { (key: String) -> URL in URL(string: bundled[key] ?? process[key] ?? "https://fixture.invalid") ?? URL(fileURLWithPath: "/dev/null") }
        let development = isDebugBuild || bundleID == "com.cmuxterm.app.debug.next" && devAccount == .staging
        let selection = CloudRuntimeSelection(name: development ? "dev" : "prod", apiOrigin: value("CMUX_VM_API_BASE_URL"),
            authWebOrigin: value("CMUX_AUTH_WWW_ORIGIN"), vmOrigin: value("CMUX_VM_API_BASE_URL"), platformOrigin: value("CMUX_NEXT_PLATFORM_PREVIEW_API_URL"),
            mobileOrigin: value("CMUX_MOBILE_API_BASE_URL"), deviceHubOrigin: value("CMUX_DEVICE_HUB_URL"), shareRoomOrigin: value("CMUX_SHARE_ROOM_URL"),
            shareApiOrigin: value("CMUX_NEXT_FEED_API_URL"), stackOrigin: value("CMUX_STACK_BASE_URL"), stackProjectId: bundled["CMUX_STACK_PROJECT_ID"] ?? "fixture", stackClientKey: bundled["CMUX_STACK_CLIENT_KEY"] ?? "",
            bundleId: bundleID ?? "fixture", mutable: true, authNamespace: "fixture", legacyStorage: true,
            authStorageNamespace: bundleID == "com.cmuxterm.app.debug.next" ? (bundled["CMUX_STACK_PROJECT_ID"] ?? "fixture") : nil)
        return CloudConfiguration.from(selection: selection, bundleID: bundleID, bundled: bundled, process: process, isDebugBuild: isDebugBuild)
    }
}
