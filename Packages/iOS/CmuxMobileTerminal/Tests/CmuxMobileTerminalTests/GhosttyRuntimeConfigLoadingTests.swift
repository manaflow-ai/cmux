#if canImport(UIKit)
import Foundation
import GhosttyKit
import Testing
@testable import CmuxMobileTerminal

@MainActor
@Test("runtime loads the app-owned iOS config file")
func runtimeLoadsAppOwnedIOSConfigFile() throws {
    let fileManager = FileManager()
    let configRootURL = fileManager.temporaryDirectory
        .appendingPathComponent("cmux-ghostty-config-\(UUID().uuidString)", isDirectory: true)
    let configFileURL = configRootURL
        .appendingPathComponent("ghostty", isDirectory: true)
        .appendingPathComponent("config", isDirectory: false)
    try fileManager.createDirectory(
        at: configFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "focus-follows-mouse = true".write(to: configFileURL, atomically: true, encoding: .utf8)
    defer { try? fileManager.removeItem(at: configRootURL) }

    let runtime = try GhosttyRuntime(
        fileManager: fileManager,
        iOSConfigRootURL: configRootURL
    )
    let config = try #require(runtime.config)
    var focusFollowsMouse = false
    let key = "focus-follows-mouse"

    #expect(
        ghostty_config_get(
            config,
            &focusFollowsMouse,
            key,
            UInt(key.lengthOfBytes(using: .utf8))
        )
    )
    #expect(focusFollowsMouse)
}
#endif
