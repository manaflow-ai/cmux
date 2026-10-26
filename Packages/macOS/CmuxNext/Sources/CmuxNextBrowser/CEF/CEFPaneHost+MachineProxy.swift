import Foundation

/// A remote machine's localhost store (plans/cmux-next/remote-localhost.md): its request context
/// sends every request, loopback included, to the app's proxy, so the context must use the proxy
/// before its first request, or localhost would reach this Mac. No window of the store opens until
/// the shim says the proxy is stored (fail closed), in both backends (task 023 of
/// plans/cmux-next/chrome-parity/p01-process.md).
///
/// `cmux_shim_set_context_proxy` is a post, sent in order before the state query and the window's
/// `create_window`; `cmux_shim_context_proxy_state` answers at once in process and in the host's
/// REPLY in host mode (``CEFRuntime/sendAsync(_:)``), as `applyProfileProxy` does for a profile's
/// own proxy.
extension CEFPaneHost {
    /// Whether a context's proxy state lets its first page open: 1 (stored, applied when the context
    /// initializes) or 2 (applied). 0 is none (never stored) and -1 Chromium refused the preference
    /// (cmux_cef_shim.h, `cmux_shim_context_proxy_state`).
    static func machineProxyAllowsPages(state: Int32) -> Bool { state >= 1 }

    /// Whether `tab`'s window may be asked for now under `store`'s proxy. In process the shim answers
    /// in the call. In host mode the host's REPLY answers later (`.waiting`), and the tab asks for
    /// its window in the turn after it (``createAfterMachineProxy(_:_:)``).
    func machineProxyGate(_ tab: CEFTab, _ store: BrowserMachineStore, contextKey: String) -> CEFProfileProxyGate {
        // Asked already: the answer to that question creates the window.
        guard !machineProxyWaits.contains(ObjectIdentifier(tab)) else { return .waiting }
        switch sendMachineProxy(store, contextKey: contextKey) {
        case .now(let state):
            return Self.machineProxyAllowsPages(state: state) ? .open : .refused
        case .unsent:
            return .refused
        case .later(let token):
            createAfterMachineProxy(tab, .later(token))
            return .waiting
        }
    }

    /// Hands `store`'s proxy for `contextKey` to the shim and asks for its state.
    func sendMachineProxy(_ store: BrowserMachineStore, contextKey: String) -> CEFShimAnswer<Int32> {
        // The shim stores no proxy on port 0 (ContextProxyPortValid) and would keep an older one.
        guard store.proxyPort != 0 else { return .unsent }
        return runtime.sendAsync { shim in
            _ = shim.setContextProxy(contextKey, Int32(store.proxyPort))
            return shim.contextProxyState(contextKey)
        }
    }

    /// Host mode: asks for `tab`'s window once the host's REPLY says the proxy is stored, or fails
    /// the tab when it does not (no answer, the host gone, a refused preference).
    func createAfterMachineProxy(_ tab: CEFTab, _ state: CEFShimAnswer<Int32>) {
        let id = ObjectIdentifier(tab)
        guard machineProxyWaits.insert(id).inserted else { return }
        runtime.whenAnswered(state, label: "machine proxy state") { [weak self, weak tab] answer in
            // Out of the REPLY's delivery, as `awaitProfileProxy`'s verdict runs.
            self?.endOfTurn { [weak self, weak tab] in
                self?.machineProxyWaits.remove(id)
                guard let self, let tab, !tab.isClosed, tabs.contains(where: { $0 === tab }) else { return }
                guard let answer, Self.machineProxyAllowsPages(state: answer) else { return tab.creationFailed() }
                if ensureCreated(tab, machineProxyApplied: true), visibleTab === tab, !tab.awaitsWindowMove {
                    showBrowser(of: tab, activate: false)
                }
            }
        }
    }
}
