import Foundation
import Testing
@testable import CMUXSocketPathDomain

@Test func markerFilesAreVariantAware() {
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app",
        environment: [:]
    ) == .stable)
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app.nightly",
        environment: [:]
    ) == .nightly(slug: nil))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app.debug.agent",
        environment: [:]
    ) == .dev(slug: "agent"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app.debug",
        environment: ["CMUX_TAG": "Issue 3542"]
    ) == .dev(slug: "issue-3542"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app.debug",
        environment: ["CMUX_TAG": "café"]
    ) == .dev(slug: "caf"))
}

@Test func defaultSocketPathsStayVariantScoped() {
    let appSupport = URL(fileURLWithPath: "/support/cmux", isDirectory: true)

    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/stable/cmux.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.nightly",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/tmp/cmux-nightly.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.staging.my-feature",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/tmp/cmux-staging-my-feature.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.debug",
        environment: ["CMUX_TAG": "Issue 3542"],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/tmp/cmux-debug-issue-3542.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.nightly.review",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock",
        appSupportDirectory: appSupport
    ) == "/support/cmux/com.cmuxterm.app.nightly.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.staging.review",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock",
        appSupportDirectory: appSupport
    ) == "/support/cmux/com.cmuxterm.app.staging.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.debug",
        environment: ["CMUX_TAG": "Issue 3542"],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock",
        appSupportDirectory: appSupport
    ) == "/support/cmux/com.cmuxterm.app.dev.issue-3542.sock")
}

@Test func socketPathFallsBackWhenDirectoryExhaustsSocketBudget() {
    let longDirectory = URL(
        fileURLWithPath: "/\(String(repeating: "very-long-directory/", count: 8))cmux",
        isDirectory: true
    )
    let path = SocketPathMarkerFiles.socketPath(
        fileName: "com.cmuxterm.app.dev.\(String(repeating: "feature-", count: 12))caf\u{00e9}.sock",
        directory: longDirectory
    )

    #expect(path.hasPrefix("/tmp/"))
    #expect(path.hasSuffix(".sock"))
    #expect(path.utf8.count <= testUnixSocketPathMaxLength)
}

private let testUnixSocketPathMaxLength: Int = {
    #if os(Linux)
    return 107
    #else
    return 103
    #endif
}()
