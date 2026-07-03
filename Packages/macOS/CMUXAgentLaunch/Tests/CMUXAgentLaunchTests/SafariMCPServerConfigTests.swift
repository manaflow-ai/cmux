import CMUXAgentLaunch
import Foundation
import Testing

@Suite("SafariMCPServerConfig")
struct SafariMCPServerConfigTests {
    @Test("Resolves executable override path and emits Codex MCP overrides")
    func resolvesExecutableOverridePathAndEmitsCodexOverrides() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-safari-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let driver = root.appendingPathComponent("safaridriver", isDirectory: false)
        try Data("#!/bin/sh\n".utf8).write(to: driver, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driver.path)

        let resolved = SafariMCPServerConfig.resolvedDriverPath(
            environment: ["CMUX_SAFARI_MCP_DRIVER_PATH": driver.path]
        )
        #expect(resolved == driver.path)
        #expect(SafariMCPServerConfig.codexConfigOverrides(driverPath: driver.path) == [
            "mcp_servers.safari-mcp-stp.command=\"\(driver.path)\"",
            "mcp_servers.safari-mcp-stp.args=[\"--mcp\"]",
        ])
    }

    @Test("Opt-out disables Safari MCP resolution")
    func optOutDisablesSafariMCPResolution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-safari-mcp-disabled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let driver = root.appendingPathComponent("safaridriver", isDirectory: false)
        try Data("#!/bin/sh\n".utf8).write(to: driver, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driver.path)

        let resolved = SafariMCPServerConfig.resolvedDriverPath(
            environment: [
                "CMUX_SAFARI_MCP_DISABLED": "1",
                "CMUX_SAFARI_MCP_DRIVER_PATH": driver.path,
            ]
        )
        #expect(resolved == nil)
    }
}
