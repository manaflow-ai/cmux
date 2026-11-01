// DEBUG and Demo builds only: never compiled into Production.
#if os(iOS) && DEBUG
import CmuxMobileTransport
import Darwin
import Foundation
import os

private let log = Logger(subsystem: "dev.cmux.mobile", category: "upload-probe")

/// DEBUG only: the upload leg of `cmux_next_pair_e2e.py` (scripts/ci). Launched
/// with `-CmuxMobileUploadProbe <file> -CmuxMobileUploadProbeCwd <Mac folder>
/// [-CmuxMobileUploadProbeMac <Mac name>]`, the first link served after pairing
/// (to the named Mac, when one is named) streams `<file>` to it with the
/// app's own `LinkUpload.upload(fileAt:)` and writes `Documents/upload-probe.json`:
/// the Mac's path or its refusal, the seconds it took and the app's memory
/// footprint (`phys_footprint`) before and at its peak during the upload, so the
/// rig checks the file arrived whole and was never held whole in memory.
/// Attachments take arbitrarily large files of any type; there is no size cap.
@MainActor
enum UploadProbe {
    private static var started = false

    static func start(on link: any MacLink, macName: String) {
        let defaults = UserDefaults.standard
        guard !started, let file = defaults.string(forKey: "CmuxMobileUploadProbe"),
              defaults.string(forKey: "CmuxMobileUploadProbeMac").map({ $0 == macName }) ?? true else { return }
        started = true
        let cwd = defaults.string(forKey: "CmuxMobileUploadProbeCwd")
        Task.detached(priority: .userInitiated) { await run(file: URL(fileURLWithPath: file), cwd: cwd, link: link) }
    }

    nonisolated private static func run(file: URL, cwd: String?, link: any MacLink) async {
        let before = footprint()
        let peak = OSAllocatedUnfairLock(initialState: before)
        // Samples the footprint every 20 ms; stops when the upload ends (cancelled below).
        let sampler = Task.detached {
            while !Task.isCancelled {
                let now = footprint()
                peak.withLock { $0 = max($0, now) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let startedAt = ContinuousClock.now
        var result: [String: Any] = [:]
        do {
            result["path"] = try await LinkUpload.upload(fileAt: file, name: file.lastPathComponent, cwd: cwd, over: link)
        } catch let failure as LinkUpload.Failure {
            result["error"] = failure.code
            result["message"] = failure.message
        } catch {
            result["error"] = "failed"
            result["message"] = String(describing: error)
        }
        sampler.cancel()
        let after = footprint()
        peak.withLock { $0 = max($0, after) }
        let took = (ContinuousClock.now - startedAt).components
        result["seconds"] = Double(took.seconds) + Double(took.attoseconds) / 1e18
        result["footprintBefore"] = before
        result["footprintPeak"] = peak.withLock { $0 }
        log.info("upload probe: \(String(describing: result), privacy: .public)")
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: result) else { return }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try? data.write(to: documents.appendingPathComponent("upload-probe.json"), options: .atomic)
    }

    /// The app's memory footprint in bytes, as Xcode's memory gauge shows it.
    nonisolated private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
