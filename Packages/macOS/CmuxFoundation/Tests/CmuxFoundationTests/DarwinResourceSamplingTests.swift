import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

struct DarwinResourceSamplingTests {
    @Test("Unreadable process topology remains explicitly incomplete")
    func missingTopology() {
        let listing = DarwinProcessEnumerator(
            listPIDs: { pointer, _ in
                guard let pointer else { return 2 }
                let pids = pointer.assumingMemoryBound(to: pid_t.self)
                pids[0] = 42
                pids[1] = 43
                return 2
            },
            readProcess: { pid in
                guard pid == 42 else { return nil }
                var info = proc_bsdinfo()
                info.pbi_pid = UInt32(pid)
                return info
            }
        ).capture()
        #expect(!listing.isComplete)
        #expect(listing.missingProcessCount == 1)
    }

    @Test("Truncated PID buffers remain incomplete after bounded retries")
    func growingProcessTableFailsClosed() {
        var readCount = 0
        let listing = DarwinProcessEnumerator(
            listPIDs: { pointer, bytes in
                guard let pointer else { return 1 }
                readCount += 1
                let count = Int(bytes) / MemoryLayout<pid_t>.stride
                let pids = pointer.assumingMemoryBound(to: pid_t.self)
                for index in 0..<count { pids[index] = pid_t(index + 1) }
                return Int32(count)
            },
            readProcess: { pid in
                var info = proc_bsdinfo()
                info.pbi_pid = UInt32(pid)
                return info
            }
        ).capture()
        #expect(readCount == 3)
        #expect(!listing.isComplete)
        #expect(!listing.processes.isEmpty)
    }

    @Test("Topology fallback preserves kernel parent and process generation")
    func publicTopologyFallbackRetainsIdentity() throws {
        let info = try #require(DarwinProcessInfoReader().fallbackBSDInfo(getpid()))
        #expect(info.pbi_pid == UInt32(getpid()))
        #expect(info.pbi_ppid == UInt32(getppid()))
        #expect(info.pbi_pgid == UInt32(getpgrp()))
        #expect(info.pbi_start_tvsec > 0)
    }

    @Test("FD telemetry distinguishes allocated slots from actual open descriptors")
    func liveDescriptorTypesAreMeasured() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let sample = DarwinFileDescriptorSnapshot()
        try #require(sample.isComplete)
        #expect(sample.typeCounts["pipe", default: 0] >= 2)
        let tableCapacity = try #require(sample.tableCapacity)
        #expect(tableCapacity >= sample.typeCounts.values.reduce(0, +))
        #expect(DarwinFileDescriptorSnapshot(processID: -1).isComplete == false)
    }

}
