public import CmuxNextWakeups
package import Darwin
public import Foundation

/// Whether WebKit's setup answers on this host, asked off the main thread before a web view is
/// made where nobody waits for it (the New Tab spare). A WKWebView's first load issues sandbox
/// extensions and registers the user's fonts on the main thread; with a wedged sandboxd that held
/// launch for more than 10 s (cua-2, 2026-10-14). Unknown until ``probe()``; ready when the
/// sandbox broker answered; slow when it did not answer within ``timeout``, or a caller saw a web
/// view hold the main thread (``markSlow()``). A slow setup stays slow for the run.
public final class WebKitSetupGate {
    public enum State: Sendable { case unknown, probing, ready, slow }
    public private(set) var state = State.unknown
    public static let timeout: Duration = .seconds(2)
    /// The blocking request, run on a thread of its own; tests put a wedged one in its place.
    public var request: @Sendable () -> Void = WebKitSetupGate.issueSandboxExtension
    private let timer = DemandTimer(owner: "WebKitSetupGate.timeout")

    public init() {}

    /// Starts the request once; `answered` runs on the main actor if it answers in time.
    public func probe(answered: @escaping @MainActor () -> Void) {
        guard state == .unknown else { return }
        state = .probing
        let request = request
        // A wedged sandboxd never returns: not on a cooperative thread.
        Thread.detachNewThread {
            request()
            Task { @MainActor [weak self] in
                guard let self, state == .probing else { return }
                state = .ready
                answered()
            }
        }
        timer.schedule(after: Self.timeout) { @MainActor [weak self] in
            if self?.state == .probing { self?.state = .slow }
        }
    }

    public func markSlow() { state = .slow }

    /// Issues and drops one read extension for the temporary folder, as WebKit's first load does.
    @Sendable public nonisolated static func issueSandboxExtension() {
        typealias Issue = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_issue_file") else { return }
        free(unsafeBitCast(symbol, to: Issue.self)("com.apple.app-sandbox.read", NSTemporaryDirectory(), 0))
    }
}
