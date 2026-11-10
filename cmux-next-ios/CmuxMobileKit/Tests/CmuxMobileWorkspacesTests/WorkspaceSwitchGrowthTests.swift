import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

// iOS reliability matrix, axis `growth`: switching workspace, run 10 times to warm up,
// then to N=10 and N=200, with the process's resident memory and the app's folders read
// after each phase. The same method and bounds as CmuxMobileLiveTests/GrowthMatrixTests.swift
// (its header says why); this cell lives here because the workspace page's source is in
// CmuxMobileWorkspaces. It measures the whole process, so it runs only in a test run of its
// own (CMUX_GROWTH_MATRIX=1).

private enum SwitchGrowth {
    static var isolated: Bool { ProcessInfo.processInfo.environment["CMUX_GROWTH_MATRIX"] == "1" }

    static func footprint() -> Int64 {
        _ = malloc_zone_pressure_relief(nil, 0)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(bitPattern: info.phys_footprint) : 0
    }

    /// The workspace page's folders: the terminal tab's frame cache and the row spills.
    static func diskBytes() -> Int64 {
        let files = FileManager.default
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first ?? files.temporaryDirectory
        var total: Int64 = 0
        for root in [caches.appending(path: "RowSpill"), caches.appending(path: "cmux-mobile-terminal-frames")] {
            guard let walk = files.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in walk {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }
}

@MainActor
@Suite(.serialized, .enabled(if: SwitchGrowth.isolated, "measures the whole process: runs alone (CMUX_GROWTH_MATRIX=1)"))
struct WorkspaceSwitchGrowthTests {
    /// One switch: the workspace page's source is built for the next workspace (as its
    /// screen builds it), its tabs listed, its opening tab activated and the workspace marked
    /// seen; the page before it is let go.
    @Test(.timeLimit(.minutes(5))) func cellGrowthWorkspaceSwitch() async throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
        let ids = store.activeWorkspaces.map(\.id)
        try #require(ids.count > 1)
        var done = 0
        func run(to count: Int) async {
            while done < count {
                let id = ids[done % ids.count]
                let source = WorkspaceTabsSource(store: store, workspaceID: id, creator: creator)
                if let tab = source.tabs.first { source.activate(tab.id) }
                store.markSeen(id)
                await Task.yield()
                done += 1
            }
            for _ in 0 ..< 50 { await Task.yield() }
        }
        await run(to: 10)
        let memory0 = SwitchGrowth.footprint(), disk0 = SwitchGrowth.diskBytes()
        await run(to: 20)
        let memory1 = SwitchGrowth.footprint(), disk1 = SwitchGrowth.diskBytes()
        await run(to: 210)
        let memory2 = SwitchGrowth.footprint(), disk2 = SwitchGrowth.diskBytes()
        let memorySmall = memory1 - memory0, memoryLarge = memory2 - memory0
        let diskSmall = disk1 - disk0, diskLarge = disk2 - disk0
        let memoryPerOperation = (memoryLarge - memorySmall) / 190
        let diskPerOperation = (diskLarge - diskSmall) / 190
        let fields: [String: Any] = [
            "cell": "growth_workspace_switch", "variant": "n10-vs-n200",
            "mem_n10_kb": memorySmall / 1024, "mem_n200_kb": memoryLarge / 1024, "mem_b_per_op": memoryPerOperation,
            "disk_n10_b": diskSmall, "disk_n200_b": diskLarge, "disk_b_per_op": diskPerOperation,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("MATRIX \(text)")
        }
        // The bounds of GrowthProbe (CmuxMobileLiveTests/GrowthMatrixTests.swift).
        #expect(memoryLarge <= 8 << 20, "memory grew \(memoryLarge / 1024) KB over 200 switches after warm-up")
        #expect(memoryPerOperation <= 4 << 10, "\(memoryPerOperation) bytes of memory per switch (N=10: \(memorySmall / 1024) KB, N=200: \(memoryLarge / 1024) KB)")
        #expect(diskLarge <= 64 << 10, "the app's folders grew \(diskLarge) bytes over 200 switches")
        #expect(diskPerOperation <= 64, "\(diskPerOperation) bytes of disk per switch")
    }
}
