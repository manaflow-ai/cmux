import Darwin

extension CmuxConfigActionCatalogProcessReader {
    struct ProcessOperations: Sendable {
        typealias Wait = @Sendable (
            _ pid: pid_t,
            _ options: Int32
        ) -> CmuxConfigActionCatalogProcessWaitResult

        let wait: Wait
        let sendSignal: @Sendable (_ pid: pid_t, _ signal: Int32, _ group: Bool) -> Void

        init(
            wait: Wait? = nil,
            sendSignal: @escaping @Sendable (
                _ pid: pid_t,
                _ signal: Int32,
                _ group: Bool
            ) -> Void
        ) {
            self.wait = wait ?? Self.liveWait
            self.sendSignal = sendSignal
        }

        static let live = ProcessOperations(
            wait: liveWait
        ) { pid, signal, group in
            _ = Darwin.kill(group ? -pid : pid, signal)
        }

        private static let liveWait: Wait = { processIdentifier, options in
            var status: Int32 = 0
            errno = 0
            let result = Darwin.waitpid(processIdentifier, &status, options)
            return CmuxConfigActionCatalogProcessWaitResult(
                processIdentifier: result,
                status: status,
                errorNumber: result == -1 ? errno : 0
            )
        }
    }
}
