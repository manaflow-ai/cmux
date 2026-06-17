import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for ``MobileShellComposite/unifiedWorkspaces``: the flag-gated
/// merge of the active Mac's live workspaces with the aggregator's per-device
/// slices, presence gating, ordering, and FLAG OFF parity.
@MainActor
@Suite struct UnifiedWorkspacesMergeTests {
    private func makeWorkspace(
        id: String,
        deviceId: String = "",
        isPinned: Bool = false,
        lastActivityAt: Date? = nil
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            deviceId: deviceId,
            name: "WS \(id)",
            isPinned: isPinned,
            lastActivityAt: lastActivityAt,
            terminals: [MobileTerminalPreview(id: .init(rawValue: "\(id)-t"), deviceId: deviceId, name: "T")]
        )
    }

    private func onlineInstance(_ deviceId: String) -> PresenceInstance {
        PresenceInstance(deviceId: deviceId, tag: "default", platform: "mac", online: true, lastSeenAt: 1000)
    }

    private func offlineInstance(_ deviceId: String) -> PresenceInstance {
        PresenceInstance(deviceId: deviceId, tag: "default", platform: "mac", online: false, lastSeenAt: 1000)
    }

    @Test func mergesActiveAndAggregatorSlicesWhenOnline() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = [makeWorkspace(id: "live-1")]
        store.debugSetActiveDeviceID("mac-active")
        // Two other online Macs each contribute a slice.
        store.debugApplyPresence(.online(onlineInstance("mac-2")))
        store.debugApplyPresence(.online(onlineInstance("mac-3")))
        store.multiMacAggregator.debugSetSlice(
            deviceID: "mac-2",
            workspaces: [makeWorkspace(id: "ws-2", deviceId: "mac-2")]
        )
        store.multiMacAggregator.debugSetSlice(
            deviceID: "mac-3",
            workspaces: [makeWorkspace(id: "ws-3", deviceId: "mac-3")]
        )

        let unified = store.unifiedWorkspaces
        let ids = Set(unified.map(\.id.rawValue))
        #expect(ids == ["live-1", "ws-2", "ws-3"])
        // The active Mac's workspace is tagged with the active device id.
        let live = unified.first { $0.id.rawValue == "live-1" }
        #expect(live?.deviceId == "mac-active")
        #expect(live?.terminals.first?.deviceId == "mac-active")
    }

    @Test func offlineDeviceSlicesAreGatedOut() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = [makeWorkspace(id: "live-1")]
        store.debugSetActiveDeviceID("mac-active")
        // mac-2 is online, mac-3 is offline. Only mac-2 contributes.
        store.debugApplyPresence(.online(onlineInstance("mac-2")))
        store.debugApplyPresence(.offline(offlineInstance("mac-3"), reason: .timeout))
        store.multiMacAggregator.debugSetSlice(
            deviceID: "mac-2",
            workspaces: [makeWorkspace(id: "ws-2", deviceId: "mac-2")]
        )
        store.multiMacAggregator.debugSetSlice(
            deviceID: "mac-3",
            workspaces: [makeWorkspace(id: "ws-3", deviceId: "mac-3")]
        )

        let ids = Set(store.unifiedWorkspaces.map(\.id.rawValue))
        #expect(ids == ["live-1", "ws-2"])
    }

    @Test func unknownPresenceDeviceIsGatedOut() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = [makeWorkspace(id: "live-1")]
        store.debugSetActiveDeviceID("mac-active")
        // No presence ever seen for mac-2: it must not passively merge.
        store.multiMacAggregator.debugSetSlice(
            deviceID: "mac-2",
            workspaces: [makeWorkspace(id: "ws-2", deviceId: "mac-2")]
        )

        let ids = Set(store.unifiedWorkspaces.map(\.id.rawValue))
        #expect(ids == ["live-1"])
    }

    @Test func staleActiveDeviceSliceIsNeverDoubleListed() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = [makeWorkspace(id: "live-1")]
        store.debugSetActiveDeviceID("mac-active")
        // A stale slice for the active device (e.g. fetched before it became
        // active) must not produce a duplicate list entry.
        store.debugApplyPresence(.online(onlineInstance("mac-active")))
        store.multiMacAggregator.debugSetSlice(
            deviceID: "mac-active",
            workspaces: [makeWorkspace(id: "live-1", deviceId: "mac-active")]
        )

        #expect(store.unifiedWorkspaces.map(\.id.rawValue) == ["live-1"])
    }

    @Test func ordersPinnedFirstThenLastActivityDescending() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let workspaces = [
            makeWorkspace(id: "old", deviceId: "m1", lastActivityAt: base),
            makeWorkspace(id: "pinned-old", deviceId: "m1", isPinned: true, lastActivityAt: base),
            makeWorkspace(id: "new", deviceId: "m2", lastActivityAt: base.addingTimeInterval(100)),
            makeWorkspace(id: "pinned-new", deviceId: "m2", isPinned: true, lastActivityAt: base.addingTimeInterval(100)),
            makeWorkspace(id: "no-activity", deviceId: "m2", lastActivityAt: nil),
        ]

        let ordered = MobileShellComposite.orderedForUnifiedList(workspaces).map(\.id.rawValue)
        // Pinned first (newest pinned before older pinned), then unpinned by
        // recency, then no-activity last.
        #expect(ordered == ["pinned-new", "pinned-old", "new", "old", "no-activity"])
    }

    @Test func flagOffIsByteIdenticalToTaggedActiveWorkspaces() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: false)
        store.workspaces = [makeWorkspace(id: "live-1"), makeWorkspace(id: "live-2")]
        store.debugSetActiveDeviceID("mac-active")
        // Even with online Macs and aggregator slices present, FLAG OFF must
        // ignore them entirely.
        store.debugApplyPresence(.online(onlineInstance("mac-2")))
        store.multiMacAggregator.debugSetSlice(
            deviceID: "mac-2",
            workspaces: [makeWorkspace(id: "ws-2", deviceId: "mac-2")]
        )

        // unifiedWorkspaces == workspaces tagged with activeDeviceID, in the
        // same order, and nothing from the aggregator.
        let expected = store.workspaces.map { workspace -> MobileWorkspacePreview in
            var tagged = workspace
            tagged.deviceId = "mac-active"
            tagged.terminals = tagged.terminals.map { terminal in
                var terminal = terminal
                terminal.deviceId = "mac-active"
                return terminal
            }
            return tagged
        }
        #expect(store.unifiedWorkspaces == expected)
        #expect(store.unifiedWorkspaces.map(\.id.rawValue) == ["live-1", "live-2"])
    }

    @Test func flagOffWithNilActiveDeviceLeavesWorkspacesUntouched() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: false)
        store.workspaces = [makeWorkspace(id: "live-1")]
        // No active device id (preview / manual ticket): the list equals
        // workspaces exactly, unscoped.
        #expect(store.unifiedWorkspaces == store.workspaces)
        #expect(store.unifiedWorkspaces.first?.deviceId == "")
    }
}
