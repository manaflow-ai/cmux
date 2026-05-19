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
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/com.cmuxterm.app.sock"
    ) == "/stable/com.cmuxterm.app.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.nightly",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/com.cmuxterm.app.sock"
    ) == "/stable/com.cmuxterm.app.nightly.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.staging.my-feature",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/com.cmuxterm.app.sock"
    ) == "/stable/com.cmuxterm.app.staging.my-feature.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.debug",
        environment: ["CMUX_TAG": "Issue 3542"],
        isDebugBuild: false,
        stableSocketPath: "/stable/com.cmuxterm.app.sock"
    ) == "/stable/com.cmuxterm.app.dev.issue-3542.sock")
}

@Test func longDevSocketPathsAreBoundedForUnixSockets() {
    let path = SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.debug.issue.3993.cli.socket.stolen.by.tmux.dev",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/Users/austinwang/Library/Application Support/cmux/com.cmuxterm.app.sock"
    )

    #expect(path.hasPrefix("/Users/austinwang/Library/Application Support/cmux/com.cmuxterm.app.dev.issue-3993"))
    #expect(path.hasSuffix(".sock"))
    #expect(path.utf8.count <= 103)
}

@Test func nilSlugSocketFileNamesAreShortenedWhenNeeded() {
    let directoryPath = "/Users/austinwang/Library/Application Support/cmux"
    let fileName = SocketPathMarkerFiles.socketFileName(
        filePrefix: String(repeating: "very-long-prefix-", count: 5),
        slug: nil,
        directoryPath: directoryPath,
        maxSocketPathLength: 103
    )
    let path = "\(directoryPath)/\(fileName)"

    #expect(fileName.hasSuffix(".sock"))
    #expect(path.utf8.count <= 103)
}
