import Darwin

extension CmuxConfigActionCatalogProcessReader {
    struct ProcessOperations: Sendable {
        let sendSignal: @Sendable (_ pid: pid_t, _ signal: Int32, _ group: Bool) -> Void

        static let live = ProcessOperations { pid, signal, group in
            _ = Darwin.kill(group ? -pid : pid, signal)
        }
    }
}
