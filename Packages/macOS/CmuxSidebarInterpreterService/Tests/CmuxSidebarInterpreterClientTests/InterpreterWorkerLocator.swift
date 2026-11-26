import Foundation

/// Locates the built `cmux-sidebar-interpreter` worker executable so the client
/// tests can spawn the real worker process.
///
/// Two runners place the binary differently:
/// - `xcodebuild test` loads a `.xctest` bundle; the worker is its sibling.
/// - `swift test` runs via an out-of-tree `swiftpm-testing-helper` and loads no
///   `.xctest`, so we derive the package root from `#filePath` and use the
///   `.build/<config>` products directory (the `.build/debug` symlink resolves
///   regardless of the host triple).
///
/// The first candidate that is an executable file wins.
func interpreterWorkerURL() -> URL {
    builtExecutableURL(named: "cmux-sidebar-interpreter")
}

/// Locates the built `cmux-sidebar-render-fixture` protocol fixture for the
/// `RenderWorkerClient` supervision tests (same lookup rules as the worker).
func renderFixtureURL() -> URL {
    builtExecutableURL(named: "cmux-sidebar-render-fixture")
}

private func builtExecutableURL(named workerName: String) -> URL {
    let fileManager = FileManager.default
    var candidates: [URL] = []

    #if os(macOS)
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(workerName))
    }
    #endif

    // <package>/Tests/CmuxSidebarInterpreterClientTests/<thisFile>
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildDirectory = packageRoot.appendingPathComponent(".build")
    candidates.append(buildDirectory.appendingPathComponent("debug").appendingPathComponent(workerName))
    candidates.append(buildDirectory.appendingPathComponent("release").appendingPathComponent(workerName))
    if let triples = try? fileManager.contentsOfDirectory(at: buildDirectory, includingPropertiesForKeys: nil) {
        for triple in triples {
            candidates.append(triple.appendingPathComponent("debug").appendingPathComponent(workerName))
            candidates.append(triple.appendingPathComponent("release").appendingPathComponent(workerName))
        }
    }

    for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    return candidates.first ?? URL(fileURLWithPath: workerName)
}
