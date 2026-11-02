#if os(iOS)
import QuartzCore

/// Resumes at the next display frame (a one-shot display link), where streamed
/// changes are applied together.
@MainActor
final class DisplayFrame: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var link: CADisplayLink?

    static func next() async {
        await withCheckedContinuation { continuation in
            let frame = DisplayFrame()
            frame.continuation = continuation
            let link = CADisplayLink(target: frame, selector: #selector(tick))
            frame.link = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func tick() {
        link?.invalidate()
        link = nil
        continuation?.resume()
        continuation = nil
    }
}

extension AgentChatStore {
    static var defaultNextFrame: (@MainActor () async -> Void)? { { await DisplayFrame.next() } }
}
#else
extension AgentChatStore {
    /// No display on the host running the tests: every event applies at once.
    static var defaultNextFrame: (@MainActor () async -> Void)? { nil }
}
#endif
