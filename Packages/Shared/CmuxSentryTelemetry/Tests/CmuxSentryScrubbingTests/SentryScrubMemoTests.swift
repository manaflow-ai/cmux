import Foundation
import Testing

@testable import CmuxSentryScrubbing

/// The memo behind ``SentryScrubber/scrub(_:)``: same output as the regex pass,
/// bounded, and the lag-spike payload's cost before and after (cmux NIGHTLY
/// 12aa19c: `redactSecrets` under `reportLagSpike` was 23% of a busy profile).
@Suite struct SentryScrubMemoTests {
    private static let home = "/Users/dev"

    /// Strings that hit every rule (and some that hit none), each scrubbed twice.
    private static let corpus = [
        "opening /Users/dev/secret with token=sk-fake123def456ghij",
        "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.fake-signature-not-real",
        "mail alice@example.com about redis://user:p@ss@host/db",
        "AKIAIOSFODNN7EXAMPLE in /home/bob/.aws/credentials",
        "/Applications/cmux NIGHTLY.app/Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp",
        "password=hunter2&next=/Users/alice/x",
        "nothing sensitive here",
    ]

    @Test func aRememberedResultIsExactlyTheRegexPass() {
        let plain = SentryScrubber(homeDirectory: Self.home, memoCapacity: 0)
        let memoized = SentryScrubber(homeDirectory: Self.home)
        for text in Self.corpus {
            let expected = plain.scrub(text)
            #expect(memoized.scrub(text) == expected, "first: \(text)")
            #expect(memoized.scrub(text) == expected, "remembered: \(text)")
        }
        #expect(!memoized.scrub(Self.corpus[0]).contains("sk-fake123"))
        #expect(!memoized.scrub(Self.corpus[0]).contains("/Users/dev"))
    }

    /// The UTF-16 splice keeps text around matches intact, emoji and accents included,
    /// and a long string with many matches scrubs every one.
    @Test func replaceSplicesByUTF16OffsetsAcrossNonASCIIText() {
        let scrubber = SentryScrubber(homeDirectory: Self.home, memoCapacity: 0)
        let short = scrubber.scrub("🙂 café token=abc123 then 👩‍💻 mail a@b.co é")
        #expect(short.hasPrefix("🙂 café token=<redacted-secret>"), "\(short)")
        #expect(short.hasSuffix("👩‍💻 mail <redacted-email> é"), "\(short)")
        #expect(!short.contains("abc123"))
        let line = "é👍 at /Users/alice/x token=s3cr3t; "
        let scrubbed = scrubber.scrub(String(repeating: line, count: 500))
        #expect(!scrubbed.contains("s3cr3t") && !scrubbed.contains("alice"))
        #expect(scrubbed.components(separatedBy: "é👍 at /Users/<redacted>/x token=<redacted-secret>").count == 501, "\(scrubbed.prefix(200))")
    }

    /// Canonically equal strings with different scalars ("é" composed vs "e" plus a
    /// combining accent) are separate memo entries: the home rule matches literal
    /// scalars, so a remembered result for one must never stand in for the other.
    @Test func canonicallyEqualStringsAreSeparateEntries() {
        let composedHome = "/srv/caf\u{00E9}"
        let plain = SentryScrubber(homeDirectory: composedHome, memoCapacity: 0)
        let memoized = SentryScrubber(homeDirectory: composedHome)
        let decomposed = "/srv/cafe\u{0301}/x"
        let composed = "/srv/caf\u{00E9}/x"
        #expect(decomposed == composed, "Swift treats them as equal strings")
        #expect(memoized.scrub(decomposed) == plain.scrub(decomposed))
        let scrubbed = memoized.scrub(composed)
        #expect(scrubbed == plain.scrub(composed))
        #expect(!scrubbed.unicodeScalars.elementsEqual(composed.unicodeScalars), "the home path is redacted: \(scrubbed)")
    }

    @Test func copiesShareOneMemoAndItStaysBounded() {
        let memo = SentryScrubMemo(capacity: 4)
        for index in 0..<10 { memo.remember("out\(index)", for: "in\(index)") }
        #expect(memo.entries.withLock { $0.count } <= 4)
        #expect(memo.result(for: "in9") == "out9")
        let long = String(repeating: "a", count: SentryScrubMemo.maximumLength + 1)
        memo.remember("x", for: long)
        #expect(memo.result(for: long) == nil, "long strings are not kept")
        #expect(SentryScrubMemo(capacity: 0).result(for: "in9") == nil)
    }

    /// Times N lag-spike-shaped scrubs on the calling thread, memo off (before)
    /// and on (after), in one run. Prints `lag-spike scrub bench: ...`.
    @Test func lagSpikeScrubBench() {
        let reports = 200
        let before = Self.time(reports: reports, scrubber: SentryScrubber(homeDirectory: Self.home, memoCapacity: 0))
        let after = Self.time(reports: reports, scrubber: SentryScrubber(homeDirectory: Self.home))
        func perReport(_ duration: Duration) -> Double { Double(duration / .microseconds(1)) / Double(reports) }
        let line = String(format: "lag-spike scrub bench: %d reports; before %.1f us/report (%.0f ms per 1,000); after %.1f us/report (%.0f ms per 1,000); %.1fx",
                          reports, perReport(before), perReport(before), perReport(after), perReport(after),
                          Double(before / .nanoseconds(1)) / max(1, Double(after / .nanoseconds(1))))
        print(line)
        #expect(after < before, "\(line)")
    }

    private static func time(reports: Int, scrubber: SentryScrubber) -> Duration {
        let payload = LagSpikePayload()
        let clock = ContinuousClock()
        var sink = 0
        let elapsed = clock.measure {
            for _ in 0..<reports { sink &+= payload.scrub(with: scrubber) }
        }
        #expect(sink > 0)
        return elapsed
    }
}

/// The strings one lag-spike event sends through the scrubber: 64 frames over
/// 8 images (`package`), their debug images (`codeFile`), 100 breadcrumbs
/// (`message` and `data`), device/os/app context, tags and extra.
private struct LagSpikePayload {
    let packages: [String]
    let codeFiles: [String]
    let breadcrumbs: [(message: String, data: [String: Any])]
    let context: [String: [String: Any]]
    let tags: [String: Any]
    let extra: [String: Any]

    init() {
        let images = [
            "/Applications/cmux NIGHTLY.app/Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp",
            "/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux NIGHTLY",
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
            "/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore",
            "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
            "/usr/lib/system/libsystem_kernel.dylib",
            "/usr/lib/swift/libswift_Concurrency.dylib",
        ]
        packages = (0..<64).map { images[$0 % images.count] }
        codeFiles = images
        breadcrumbs = (0..<100).map { index in
            ("window \(index % 4) became key in workspace \(index % 7)",
             ["category": "ui.lifecycle", "screen": "MainWindowController", "tab": "\(index % 9)"])
        }
        context = [
            "device": ["model": "Mac15,9", "arch": "arm64e", "family": "Mac", "locale": "en_US", "processor_count": 16],
            "os": ["name": "macOS", "version": "15.4.1", "build": "24E263", "kernel_version": "Darwin Kernel Version 24.4.0"],
            "app": ["app_name": "cmux NIGHTLY", "app_version": "0.0.0", "app_build": "12aa19c", "app_identifier": "com.cmuxterm.app.nightly"],
        ]
        tags = ["hang_source": "main_thread_stall", "stall_bucket": "250-500ms", "stall_blocked": "no"]
        extra = ["stall_ms": 310, "cpu_ms": 290, "frames": 64, "windows": "2", "visible_windows": "2", "app_active": "yes"]
    }

    /// Scrubs every field once; returns a count so the work is not optimized away.
    func scrub(with scrubber: SentryScrubber) -> Int {
        var total = 0
        total &+= scrubber.scrub("main thread stalled 250-500ms").utf8.count
        for package in packages { total &+= scrubber.scrub(package).utf8.count }
        for codeFile in codeFiles { total &+= scrubber.scrub(codeFile).utf8.count }
        for breadcrumb in breadcrumbs {
            total &+= scrubber.scrub(breadcrumb.message).utf8.count
            total &+= scrubber.scrub(dictionary: breadcrumb.data).count
        }
        total &+= scrubber.scrub(context: context).count
        total &+= scrubber.scrub(dictionary: tags).count
        total &+= scrubber.scrub(dictionary: extra).count
        return total
    }
}
