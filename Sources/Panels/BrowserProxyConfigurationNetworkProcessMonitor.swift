import Dispatch

@MainActor
final class BrowserProxyConfigurationNetworkProcessMonitor {
    private var source: DispatchSourceProcess?
    private var processIdentifier: Int?

    func observe(
        processIdentifier: Int?,
        onExit: @escaping @MainActor () -> Void
    ) {
        guard processIdentifier != self.processIdentifier else { return }
        cancel()
        guard let processIdentifier, processIdentifier > 0 else { return }

        self.processIdentifier = processIdentifier
        let source = DispatchSource.makeProcessSource(
            identifier: pid_t(processIdentifier),
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.processIdentifier == processIdentifier else { return }
                self.cancel()
                onExit()
            }
        }
        self.source = source
        source.resume()
    }

    func cancel() {
        source?.cancel()
        source = nil
        processIdentifier = nil
    }

    deinit {
        source?.cancel()
    }
}
