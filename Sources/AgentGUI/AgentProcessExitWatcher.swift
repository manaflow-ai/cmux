import Darwin
import Foundation

@MainActor
final class AgentProcessExitWatcher {
    private var sourcesByPID: [Int32: DispatchSourceProcess] = [:]
    private let onExit: @MainActor (Int32, Int) -> Void

    init(onExit: @escaping @MainActor (Int32, Int) -> Void) {
        self.onExit = onExit
    }

    func watch(pid: Int32, startTick: Int) {
        guard sourcesByPID[pid] == nil else { return }
        if kill(pid, 0) == -1, errno == ESRCH {
            onExit(pid, startTick)
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard let source = self.sourcesByPID.removeValue(forKey: pid) else { return }
                source.cancel()
                self.onExit(pid, startTick)
            }
        }
        sourcesByPID[pid] = source
        source.resume()
        if kill(pid, 0) == -1, errno == ESRCH,
           let resumedSource = sourcesByPID.removeValue(forKey: pid) {
            resumedSource.cancel()
            onExit(pid, startTick)
        }
    }

    func stopAll() {
        for source in sourcesByPID.values {
            source.cancel()
        }
        sourcesByPID.removeAll()
    }
}
