#if canImport(Darwin)
import Darwin
import Foundation
import Testing

import CmuxSentryScrubbing

/// The CPU one lag-spike event's scrub costs: the strings `SentryEventScrubber` routes through
/// ``SentryScrubber`` for a NIGHTLY lag spike (a full scope of 100 breadcrumbs with their data, the
/// stall's frames and debug images, Sentry's device/os/app contexts, tags and extra), scrubbed on one
/// thread and timed by that thread's CPU clock. A measurement, not a gate. Public API only, so the
/// same file measures a tree from before the literal gate (swift-test-bench.sh restore_from=).
///
/// ```
/// CMUX_SENTRY_SCRUB_BENCH=1 swift test -c release --filter SentryScrubCostBench
/// ```
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SENTRY_SCRUB_BENCH"] == "1"))
struct SentryScrubCostBench {
    private static let events = 200

    /// One event's scrubbed fields, in the shapes the event scrubber passes.
    private struct EventFields {
        var strings: [String] = []
        var dictionaries: [[String: Any]] = []
        var context: [String: [String: Any]] = [:]
    }

    private static func lagSpikeEvent() -> EventFields {
        var fields = EventFields()
        let messages = [
            "revealed", "blank after reveal", "foreground", "background", "focus moved to workspace 3",
            "window did become key", "GET https://api.cmux.dev/v1/teams/members?include=avatars",
            "agent session resumed after reconnect", "terminal.reveal: surface 12 shown in 41 ms",
            "daemon connection restored (attempt 2)",
        ]
        for index in 0..<100 {
            fields.strings.append(messages[index % messages.count])
            fields.dictionaries.append([
                "screen": "CmuxNextApp.MainWindowController", "surface": "\(index)", "state": "visible",
                "url": "https://api.cmux.dev/v1/workspaces/\(index)/tabs", "method": "GET", "status_code": 200,
            ])
        }
        fields.strings.append("main thread stalled 250-500ms")
        for index in 0..<60 {
            fields.strings.append("/Applications/cmux NIGHTLY.app/Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp")
            fields.strings.append(index.isMultiple(of: 3) ? "/usr/lib/system/libsystem_kernel.dylib" : "CmuxNextApp")
        }
        for index in 0..<20 {
            fields.strings.append("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit\(index)")
        }
        fields.dictionaries.append(["stall_bucket": "250-500ms", "stall_blocked": "no", "release": "nightly.4499924208601",
                                    "environment": "nightly", "cmux_next": "1", "install_id": "3F2A9C1E-5B7D-4E8A-9C21-0D4E6F8A1B2C"])
        fields.dictionaries.append(["stall_ms": 312, "cpu_ms": 120, "frames": 60, "windows": "2", "workspaces": "7", "tabs": "23"])
        fields.context = [
            "device": ["family": "Desktop", "model": "Mac16,6", "arch": "arm64e", "memory_size": 68_719_476_736,
                       "processor_count": 14, "cpu_description": "Apple M4 Max", "locale": "en_US", "thermal_state": "nominal"],
            "os": ["name": "macOS", "version": "27.0.1", "build": "26A434", "kernel_version":
                   "Darwin Kernel Version 27.0.0: Mon Oct 12 21:12:03 PDT 2026; root:xnu-12377.1.9~3/RELEASE_ARM64_T6041"],
            "app": ["app_name": "cmux NIGHTLY", "app_identifier": "com.cmuxterm.app.nightly", "app_version": "1.0.0-nightly",
                    "build_type": "app_store", "app_start_time": "2026-11-22T08:08:40Z", "device_app_hash": "8f2a1c9e0b7d"],
            "culture": ["locale": "en_US", "timezone": "America/Los_Angeles", "is_24_hour_format": false, "calendar": "GregorianCalendar"],
            "runtime": ["name": "swift", "version": "6.3"],
        ]
        return fields
    }

    private static func threadCPUNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    @Test func cpuPerLagSpikeEventScrub() {
        let scrubber = SentryScrubber(homeDirectory: "/Users/dev")
        let event = Self.lagSpikeEvent()
        var sink = 0
        func scrubOnce() {
            for string in event.strings { sink &+= scrubber.scrub(string).utf8.count }
            for dictionary in event.dictionaries { sink &+= scrubber.scrub(dictionary: dictionary).count }
            sink &+= scrubber.scrub(context: event.context).count
        }
        for _ in 0..<10 { scrubOnce() }  // warm: the static patterns compile on first use
        var perEvent: [Double] = []
        for _ in 0..<Self.events {
            let start = Self.threadCPUNanos()
            scrubOnce()
            perEvent.append(Double(Self.threadCPUNanos() - start) / 1_000)
        }
        perEvent.sort()
        let fieldCount = event.strings.count + event.dictionaries.reduce(0) { $0 + $1.count }
            + event.context.values.reduce(0) { $0 + $1.count }
        print(String(format: "sentry-scrub bench: macOS %@, %d events of %d fields: thread CPU per event median %.0f us, p90 %.0f us, min %.0f us (sink %d)",
                     ProcessInfo.processInfo.operatingSystemVersionString, Self.events, fieldCount,
                     perEvent[perEvent.count / 2], perEvent[perEvent.count * 9 / 10], perEvent[0], sink & 1))
        #expect(perEvent.count == Self.events)
    }
}
#endif
