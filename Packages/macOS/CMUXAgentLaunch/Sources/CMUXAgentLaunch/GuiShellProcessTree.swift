import Darwin
import Foundation

/// Terminates only the shell's descendants before closing its pipes.
struct GuiShellProcessTree {
    func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let root = process.processIdentifier
        var descendants: [pid_t] = []
        collectChildren(of: root, into: &descendants, depth: 0)
        for pid in descendants.reversed() { _ = kill(pid, SIGKILL) }
        if process.isRunning { _ = kill(root, SIGKILL) }
    }

    private func collectChildren(of pid: pid_t, into result: inout [pid_t], depth: Int) {
        guard depth < 32 else { return }
        var children = [pid_t](repeating: 0, count: 1024)
        let count = children.withUnsafeMutableBytes {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return }
        for child in children.prefix(min(children.count, Int(count))) where child > 0 {
            guard !result.contains(child) else { continue }
            result.append(child)
            collectChildren(of: child, into: &result, depth: depth + 1)
        }
    }
}
