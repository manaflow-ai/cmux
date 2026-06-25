import Foundation
import Testing

@testable import CmuxTaskManager

@Suite("Task Manager snapshot model parsing")
struct SnapshotModelParsingTests {
    @Test("Resources coerce NSNumber/Int/String shapes and canonicalize PIDs")
    func resourcesCoercion() {
        let resources = CmuxTaskManagerResources([
            "cpu_percent": "12.5",
            "resident_bytes": 2048,
            "process_count": NSNumber(value: 3),
            "pids": [9, 1, 9, 4],
        ])
        #expect(resources.cpuPercent == 12.5)
        #expect(resources.residentBytes == 2048)
        // memory_bytes absent -> defaults to resident_bytes.
        #expect(resources.memoryBytes == 2048)
        #expect(resources.processCount == 3)
        #expect(resources.processIds == [1, 4, 9])
    }

    @Test("memory_bytes overrides resident_bytes when present")
    func memoryBytesOverride() {
        let resources = CmuxTaskManagerResources([
            "memory_bytes": 4096,
            "resident_bytes": 1024,
        ])
        #expect(resources.memoryBytes == 4096)
        #expect(resources.residentBytes == 1024)
    }

    @Test("Diagnostic parses app/children groups; absent payload is nil")
    func diagnosticParsing() {
        #expect(CmuxTaskManagerMemoryDiagnostic(nil) == nil)

        let diagnostic = CmuxTaskManagerMemoryDiagnostic([
            "summary": "  ok  ",
            "app": ["physical_footprint_bytes": 100, "resident_bytes": 90],
            "children": [
                "recursive_rss_bytes": 50,
                "process_count": 2,
                "groups": [
                    ["name": "alpha", "process_count": 1, "rss_bytes": 10, "pids": [7]],
                    ["name": "skipme", "process_count": 0],
                ],
            ],
        ])
        let unwrapped = try! #require(diagnostic)
        #expect(unwrapped.summary == "ok")
        #expect(unwrapped.appFootprintBytes == 100)
        #expect(unwrapped.appResidentBytes == 90)
        #expect(unwrapped.childRSSBytes == 50)
        #expect(unwrapped.childProcessCount == 2)
        // The zero-process group is dropped.
        #expect(unwrapped.groups.count == 1)
        #expect(unwrapped.groups.first?.name == "alpha")
        #expect(unwrapped.groups.first?.id == "alpha")
        #expect(unwrapped.groups.first?.processIds == [7])
    }

    @Test("Attribution requires at least one identifying field")
    func attributionRequiresField() {
        #expect(CmuxTaskManagerMemoryAttribution(nil) == nil)
        #expect(CmuxTaskManagerMemoryAttribution([:]) == nil)

        let attribution = CmuxTaskManagerMemoryAttribution([
            "workspace_id": "00000000-0000-0000-0000-000000000001",
            "surface_type": "terminal",
        ])
        let unwrapped = try! #require(attribution)
        #expect(unwrapped.workspaceId?.uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(unwrapped.surfaceType == "terminal")
        #expect(unwrapped.paneId == nil)
    }
}
