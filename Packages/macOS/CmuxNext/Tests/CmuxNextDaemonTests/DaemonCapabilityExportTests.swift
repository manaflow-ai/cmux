import Foundation
import Testing
@testable import CmuxNextDaemon

/// The app's daemon capability lists and their checked-in export,
/// `plans/cmux-next/daemon-capabilities.json`, which
/// scripts/cmux-next/check-daemon-capabilities.sh compares with what the
/// bundled cmux-tui serves.
/// `CMUX_UPDATE_DAEMON_CAPABILITIES=1 swift test --filter DaemonCapabilityExportTests` rewrites it, as does
/// `python3 scripts/cmux-next/check-daemon-capabilities-fresh.py --write` with no build.
struct DaemonCapabilityExportTests {
    /// Entries in `unservedByBundledDaemon` on 2026-10-02. The list only
    /// shrinks: a new feature lands with its daemon half and goes in `optional`.
    private static let unservedCeiling: Set<String> = ["remote-terminal-tabs-v1", "detached-terminals-v1"]

    @Test func unservedListOnlyShrinks() {
        let added = Set(DaemonCapability.unservedByBundledDaemon).subtracting(Self.unservedCeiling)
        #expect(added.isEmpty, "new unserved capabilities \(added.sorted()): land the daemon half on this branch and list them in optional")
    }

    @Test func nativeRemoteHandshakeRequestsOnlySupportedOwnerSurface() {
        #expect(DaemonCapability.nativeRemoteRequired == [
            "workspace-registry-v1", "layout-delta-v1", "session-identity-v1",
            "conversation-tabs-v1", "agent-session-tabs-v1", "agent-session-start-v1",
            "agent-session-attach-v1",
        ])
        #expect(!DaemonCapability.nativeRemoteRequired.contains("viewport-splits-v1"))
        #expect(!DaemonCapability.nativeRemoteRequired.contains("view-attachment-lease-v1"))
    }

    /// The enum is written on every build from cmux-tui/spec/gui-capabilities.json
    /// (DaemonCapabilitiesPlugin): every entry is a case, in order, with its wire name and tier.
    @Test func enumIsTheCatalogJSON() throws {
        struct Catalog: Decodable {
            struct Entry: Decodable {
                var name: String
                var wire: String
                var tier: String
                enum CodingKeys: String, CodingKey {
                    case name = "case", wire, tier
                }
            }
            var capabilities: [Entry]
        }
        let url = Self.repoRoot.appendingPathComponent("cmux-tui/spec/gui-capabilities.json")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        #expect(DaemonCapability.allCases.map { String(describing: $0) } == catalog.capabilities.map(\.name))
        #expect(DaemonCapability.allCases.map(\.rawValue) == catalog.capabilities.map(\.wire))
        let tiers: [String] = DaemonCapability.allCases.map {
            switch $0.tier {
            case .required: "required"
            case .optional: "optional"
            case .unservedByBundledDaemon: "unservedByBundledDaemon"
            }
        }
        #expect(tiers == catalog.capabilities.map(\.tier))
    }

    /// What the hand-written enum gave before it moved to the catalog JSON (2026-11-25): the required
    /// list in order, and the advertised list is every listed capability but the four never echoed.
    @Test func derivedListsKeepTheirShape() {
        #expect(DaemonCapability.required == [
            "workspace-registry-v1", "viewport-splits-v1", "viewport-column-resize-v1", "layout-undo-v1",
            "view-attachment-lease-v1", "view-attachment-detach-v1", "attach-initial-size",
        ])
        #expect(DaemonCapability.required.count + DaemonCapability.optional.count
            + DaemonCapability.unservedByBundledDaemon.count == DaemonCapability.allCases.count)
        let notEchoed: Set<String> = [
            "terminal-frontend-shell-integration-v1", "placement-shift-v1", "shared-sizing-v1",
            "agent-session-presence-v1",
        ]
        #expect(Set(DaemonCapability.advertised) == Set(DaemonCapability.allCases.map(\.rawValue)).subtracting(notEchoed))
        #expect(DaemonCapability.advertised.count == DaemonCapability.allCases.count - notEchoed.count)
        #expect(DaemonCapability.isServedByBundledDaemon("workspace-registry-v1"))
        #expect(!DaemonCapability.isServedByBundledDaemon("not-a-capability-v1"))
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func exportIsFresh() throws {
        let url = Self.repoRoot
            .appendingPathComponent("plans/cmux-next/daemon-capabilities.json")
        let current = try Self.json()
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_DAEMON_CAPABILITIES"] == "1" {
            try current.write(to: url, atomically: true, encoding: .utf8)
        }
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(stored == current, "daemon-capabilities.json is stale; rerun with CMUX_UPDATE_DAEMON_CAPABILITIES=1")
    }

    static func json() throws -> String {
        struct Export: Encodable {
            var comment: String
            var required: [String]
            var optional: [String]
            var unservedByBundledDaemon: [String]
        }
        let export = Export(
            comment: "Generated by DaemonCapabilityExportTests from DaemonCapability; read by scripts/cmux-next/check-daemon-capabilities.sh.",
            required: DaemonCapability.required.sorted(),
            optional: DaemonCapability.optional.sorted(),
            unservedByBundledDaemon: DaemonCapability.unservedByBundledDaemon.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(export), as: UTF8.self) + "\n"
    }
}
