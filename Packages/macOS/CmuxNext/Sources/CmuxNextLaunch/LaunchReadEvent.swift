/// A launch read's completion as a one-shot event (Chromium's `base::OneShotEvent`,
/// base/one_shot_event.h): steps that need the read post to it and run on its ``signal()``, in post
/// order; a step posted after the signal runs at once. Nothing polls and nothing waits on main
/// (p08-startup.md 3A: a step that needs a read that is not done runs on the read's completion event).
///
/// The app's one today is the browser profiles' launch read (p08-startup-028): every browser page
/// waits for it, so no page engine starts with a profile chosen before the profiles were read.
///
/// ```swift
/// let loaded = LaunchReadEvent("BrowserProfiles.loaded")
/// loaded.post { cache.makePage(key) }   // waits
/// loaded.signal()                       // runs it
/// loaded.post { cache.makePage(other) } // runs at once
/// ```
@MainActor
public final class LaunchReadEvent {
    /// The read, in diagnostics (`Domain.read`).
    public let name: StaticString
    /// True once the read is done.
    public private(set) var isSignaled = false
    private var steps: [@MainActor () -> Void] = []

    /// - Parameter name: The read, in diagnostics (`BrowserProfiles.loaded`).
    public init(_ name: StaticString) {
        self.name = name
    }

    /// The steps still waiting for the read.
    public var waitingCount: Int { steps.count }

    /// Runs `step` once the read is done: at once when it is.
    public func post(_ step: @escaping @MainActor () -> Void) {
        guard !isSignaled else { return step() }
        steps.append(step)
    }

    /// The read is done: runs the waiting steps in post order, once. A second signal does nothing.
    public func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let waiting = steps
        steps = []
        for step in waiting { step() }
    }
}
