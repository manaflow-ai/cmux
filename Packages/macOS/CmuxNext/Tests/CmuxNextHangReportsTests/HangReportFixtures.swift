import Foundation
@testable import CmuxNextHangReports

/// Realistic MetricKit payloads and watchdog samples with planted private data. Every planted
/// string is in ``planted``; a report built from these must contain none of them.
enum HangReportFixtures {
    static let appBundle = "/Applications/cmux NEXT Nightly.app"
    static let appUUID = "3F0C9E43-7A61-3C8E-9C1A-2B7F5D0E9A11"
    static let appKitUUID = "8B1E5C0A-1D4F-3B2E-A6C7-9F8E7D6C5B4A"
    static let foundationUUID = "1A2B3C4D-5E6F-3A7B-8C9D-0E1F2A3B4C5D"
    static let imeUUID = "DEADBEEF-1111-3222-8333-444455556666"
    static let pluginUUID = "CAFEBABE-AAAA-3BBB-8CCC-DDDDEEEEFFFF"
    static let ghosttyUUID = "77A62F2E-8212-30F3-84C1-E8497440ACF8"

    /// Strings that must never reach a report (paths, names, emails, URLs, tokens, hosts, env).
    static let planted = [
        "alice", "Alice Liddell", "Liddell", "/Users/alice", "~/Library", "SecretIME", "Input Methods",
        "alice@example.com", "https://intranet.example.com/wiki", "intranet.example.com", "192.168.1.20",
        "fe80::1c2b:3a4d", "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8", "AWS_SECRET_ACCESS_KEY=abc",
        "PATH=/usr/bin", "Alices-MacBook-Pro", "WorkspaceSecretProject", "EvilPlugin", "Q3 Plans.pdf",
        "en_US", "regionFormat", "Contents/MacOS", "threadName",
    ]

    static let forbiddenTerms = ["alice", "Alice", "Liddell", "/Users/alice", "Alices-MacBook-Pro"]

    /// The images "loaded" in the fake process: ours (in the bundle), Apple's, and two third-party ones.
    static let images = [
        LoadedImage(path: appBundle + "/Contents/MacOS/cmux NEXT Nightly", uuid: appUUID, base: 0x1_0000_0000, size: 0x100_0000),
        LoadedImage(path: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", uuid: appKitUUID,
                    base: 0x1_8000_0000, size: 0x200_0000),
        LoadedImage(path: "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation", uuid: foundationUUID,
                    base: 0x1_9000_0000, size: 0x100_0000),
        LoadedImage(path: "/Users/alice/Library/Input Methods/SecretIME.app/Contents/MacOS/SecretIME", uuid: imeUUID,
                    base: 0x2_0000_0000, size: 0x10_0000),
        LoadedImage(path: "/Applications/EvilPlugin.app/Contents/MacOS/EvilPlugin", uuid: pluginUUID,
                    base: 0x2_1000_0000, size: 0x10_0000),
    ]

    struct FakeResolver: ImageResolving {
        var images = HangReportFixtures.images
        func image(containing address: UInt64) -> LoadedImage? { images.first { $0.contains(address) } }
        func image(uuid: String) -> LoadedImage? { images.first { $0.uuid == uuid.uppercased() } }
    }

    static func classifier(systemNames: Set<String> = ["AppKit", "Foundation", "libsystem_kernel.dylib", "CoreFoundation"])
        -> ImageClassifier {
        ImageClassifier(appBundlePath: appBundle, forbiddenTerms: forbiddenTerms, systemImageExists: { systemNames.contains($0) })
    }

    static func builder() -> HangReportBuilder {
        HangReportBuilder(classifier: classifier(), resolver: FakeResolver())
    }

    static func context(reportId: String = "5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11") -> HangReportBuilder.Context {
        HangReportBuilder.Context(
            reportId: reportId, installId: "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20", day: "2026-10-23",
            app: HangReport.App(version: "0.70.0", build: "70123", channel: "nightly"),
            os: HangReport.OS(version: "15.7.4"),
            hardware: HardwareClass(arch: "arm64", chip: "Apple M4 Pro", cores: 14, memoryGB: 48),
            counts: CoarseCounts(windows: 1, workspaces: 24, panes: 12, tabs: 72))
    }

    /// A hang diagnostic's call stack tree as MetricKit writes it, with a third-party input method
    /// in the stack, a full path as a binary name, a binary that is not loaded any more, and
    /// unknown keys carrying private data.
    static let hangTree = """
    {
      "callStackPerThread" : true,
      "regionFormat" : "en_US",
      "pid" : 4242,
      "callStacks" : [
        {
          "threadAttributed" : false,
          "callStackRootFrames" : [
            {"binaryUUID" : "\(foundationUUID)", "offsetIntoBinaryTextSegment" : 99, "sampleCount" : 9,
             "binaryName" : "Foundation", "address" : 6710886499}
          ]
        },
        {
          "threadAttributed" : true,
          "threadName" : "WorkspaceSecretProject alice@example.com",
          "callStackRootFrames" : [
            {
              "binaryUUID" : "\(imeUUID)",
              "offsetIntoBinaryTextSegment" : 4096,
              "sampleCount" : 20,
              "binaryName" : "/Users/alice/Library/Input Methods/SecretIME.app/Contents/MacOS/SecretIME",
              "address" : 8589938688,
              "subFrames" : [
                {
                  "binaryUUID" : "\(appKitUUID)",
                  "offsetIntoBinaryTextSegment" : 123456,
                  "sampleCount" : 20,
                  "binaryName" : "AppKit",
                  "address" : 6442573888,
                  "subFrames" : [
                    {
                      "binaryUUID" : "\(appUUID)",
                      "offsetIntoBinaryTextSegment" : 777,
                      "sampleCount" : 18,
                      "binaryName" : "cmux NEXT Nightly",
                      "address" : 4294968073,
                      "subFrames" : [
                        {"binaryUUID" : "\(ghosttyUUID)", "offsetIntoBinaryTextSegment" : 55, "sampleCount" : 18,
                         "binaryName" : "\(appBundle)/Contents/Frameworks/GhosttyKit.framework/GhosttyKit", "address" : 1}
                      ]
                    },
                    {
                      "binaryUUID" : "\(pluginUUID)",
                      "offsetIntoBinaryTextSegment" : 12,
                      "sampleCount" : 2,
                      "binaryName" : "EvilPlugin",
                      "address" : 8858370060
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
    """

    /// A CPU exception's per-process tree: two roots, the heavier one a private library that is
    /// not loaded and only has a name.
    static let cpuTree = """
    {
      "callStackPerThread" : false,
      "callStacks" : [
        {
          "callStackRootFrames" : [
            {"binaryUUID" : "\(appKitUUID)", "offsetIntoBinaryTextSegment" : 10, "sampleCount" : 3, "binaryName" : "AppKit"},
            {"binaryUUID" : "AAAAAAAA-BBBB-3CCC-8DDD-EEEEEEEEEEEE", "offsetIntoBinaryTextSegment" : 20, "sampleCount" : 40,
             "binaryName" : "libAliceTools.dylib",
             "subFrames" : [
               {"binaryUUID" : "BBBBBBBB-CCCC-3DDD-8EEE-FFFFFFFFFFFF", "offsetIntoBinaryTextSegment" : 30, "sampleCount" : 40,
                "binaryName" : "libsystem_kernel.dylib"},
               {"binaryUUID" : "not-a-uuid PATH=/usr/bin", "offsetIntoBinaryTextSegment" : 1, "sampleCount" : 1,
                "binaryName" : "Q3 Plans.pdf"}
             ]}
          ]
        }
      ]
    }
    """

    /// MetricKit signposts: one allowlisted, others with private categories or names.
    static let signposts = [
        MetricKitInput.Signpost(category: "motion", name: "motion.frame", count: 1200,
                                buckets: [HistogramBucket(lowMs: 0, highMs: 10, count: 1100), HistogramBucket(lowMs: 10, highMs: 20, count: 100)],
                                hitchMsPerS: 0.4),
        MetricKitInput.Signpost(category: "switch", name: "/Users/alice/Documents", count: 3, buckets: []),
        MetricKitInput.Signpost(category: "WorkspaceSecretProject", name: "frame", count: 3, buckets: []),
        MetricKitInput.Signpost(category: "stall", name: "stall.main", count: 3, buckets: []),
        MetricKitInput.Signpost(category: "key", name: "https://intranet.example.com/wiki", count: 1, buckets: []),
    ]

    static func metricKitInput() -> MetricKitInput {
        var metrics = HangReport.Metrics()
        metrics.hangTime = [HistogramBucket(lowMs: 0, highMs: 100, count: 40), HistogramBucket(lowMs: 100, highMs: 400, count: 3)]
        metrics.launchFirstDraw = [HistogramBucket(lowMs: 200, highMs: 300, count: 2)]
        metrics.scrollHitchMsPerS = 1.5
        return MetricKitInput(
            hangs: [MetricKitInput.Hang(durationMs: 2_340, callStackTree: Data(hangTree.utf8))],
            cpuExceptions: [MetricKitInput.CPUException(cpuMs: 90_000, sampledMs: 180_000, callStackTree: Data(cpuTree.utf8))],
            metrics: metrics, signposts: signposts)
    }

    /// Watchdog return addresses, innermost first: the input method, AppKit, our binary, the plug-in, nowhere.
    static let watchdogAddresses: [UInt] = [0x2_0000_1000, 0x1_8000_2000, 0x1_0000_0300, 0x2_1000_0040, 0x7_0000_0000]
}
