import Foundation

/// The browser host's provider link for the Chromium Host (task p01-process-233 of
/// plans/cmux-next/chrome-parity/p01-process.md): with it the host dials the browser host itself and
/// relays agent CDP for the pages cmux names ready, so an agent's DevTools traffic never runs on cmux's
/// main thread, as Chrome's remote debugging pipe runs off the browser's UI thread
/// (content/browser/devtools/devtools_pipe_handler.cc).
///
/// The credential is derived from the daemon-minted provider secret (`ProviderSecret.relayCredential`):
/// it opens a relay link and nothing else, and the secret itself never leaves cmux. The link id names
/// this app's Chromium Host in cmux's answers to the browser host (`tab.relay.direct`).
public nonisolated struct ChromiumHostRelayLink: Hashable, Sendable, CustomStringConvertible {
    public var socketPath: String
    public var credential: String
    public var linkID: String
    /// The pids the socket's peer may be: the browser host, or the daemon that holds its listener.
    public var hostPID: Int32
    public var listenerPID: Int32

    public init(socketPath: String, credential: String, linkID: String, hostPID: Int32, listenerPID: Int32) {
        self.socketPath = socketPath
        self.credential = credential
        self.linkID = linkID
        self.hostPID = hostPID
        self.listenerPID = listenerPID
    }

    /// Never the credential.
    public var description: String { "ChromiumHostRelayLink(\(socketPath), link: \(linkID))" }
}

/// What the Chromium Host relays a page as (`tab.relay.direct`): cmux's browser id of the page and the
/// link id of the host that shows it.
public nonisolated struct CEFAgentDirectTarget: Hashable, Sendable {
    public var browser: Int32
    public var linkID: String

    public init(browser: Int32, linkID: String) {
        self.browser = browser
        self.linkID = linkID
    }
}

extension CEFRemoteShim {
    typealias SetProviderLinkFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                                  Int32, Int32) -> Int32

    /// `cmux_remote_shim_set_provider_link` (ChromiumHost/client/remote_shim_runtime.h): the link for the attached
    /// host and every later one; nil ends it. Nothing with a remote dylib that has no such call.
    func setAgentRelayLink(_ link: ChromiumHostRelayLink?) {
        // SAFETY: `symbol` is dlsym on the remote dylib, never closed; the cast is the export's C type in
        // remote_shim_runtime.h, and each C string lives for the call (withCString).
        guard let pointer = unsafe symbol("cmux_remote_shim_set_provider_link") else { return }
        let set = unsafe unsafeBitCast(pointer, to: SetProviderLinkFn.self)
        guard let link else {
            _ = unsafe set(nil, nil, nil, 0, 0)
            return
        }
        _ = unsafe link.socketPath.withCString { socket in
            unsafe link.credential.withCString { credential in
                unsafe link.linkID.withCString { linkID in
                    unsafe set(socket, credential, linkID, link.hostPID, link.listenerPID)
                }
            }
        }
    }
}
