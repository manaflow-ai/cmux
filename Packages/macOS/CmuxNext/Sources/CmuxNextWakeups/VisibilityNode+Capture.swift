/// Capture votes and media: what makes a node render, or exempts its hidden work, while a person
/// may not see it (plans/cmux-next/chrome-parity/p06-scheduler.md, section B).
extension VisibilityNode {
    // MARK: Capture

    /// Starts a capture of this node for `reason` and returns its vote, which holds the node until
    /// ``VisibilityCaptureVote/release()``, as Chromium's capturer count holds until the
    /// `base::ScopedClosureRunner` that `WebContents::IncrementCapturerCount` returns runs. Votes add
    /// up: the first one and the last release each change ``isCaptured`` and ``wantsFrames`` once,
    /// with one notice per subscriber.
    ///
    /// - Parameters:
    ///   - reason: Who captures, for diagnostics (``captureReasons``).
    ///   - stayHidden: Keep ``effective`` (page visibility, the hidden timer alignment) as it is
    ///     while the node renders (Chromium's `stay_hidden`). False makes the node
    ///     ``Visibility/visible`` while the vote holds.
    public func captureVote(reason: String, stayHidden: Bool) -> VisibilityCaptureVote {
        nextVoteID &+= 1
        votes.append(CaptureRecord(id: nextVoteID, reason: reason, stayHidden: stayHidden))
        repropagate()
        return VisibilityCaptureVote(id: nextVoteID, reason: reason, stayHidden: stayHidden, node: self)
    }

    /// The reasons of the votes on this node, oldest first (diagnostics).
    public var captureReasons: [String] { votes.map(\.reason) }

    func releaseVote(_ id: UInt64) {
        guard let index = votes.firstIndex(where: { $0.id == id }) else { return }
        votes.remove(at: index)
        repropagate()
    }

    /// Calls `onChange` with ``wantsFrames`` each time it changes (the node starts or stops being
    /// visible or captured), not for the current value. Rendering work a capture must see (frame
    /// clients, view observations) follows it; work that follows page visibility uses
    /// ``subscribe(owner:_:)``. Hold the returned token as a ``subscribe(owner:_:)`` one.
    public func subscribeRendering(owner: String, _ onChange: @escaping @MainActor (Bool) -> Void) -> VisibilitySubscription {
        let subscription = VisibilitySubscription(owner: owner, node: self) { [weak self] _ in onChange(self?.wantsFrames ?? false) }
        renderingSubscriptions.removeAll { $0.subscription == nil }
        renderingSubscriptions.append(WeakSubscription(subscription: subscription))
        return subscription
    }

    // MARK: Media

    /// Records that this node starts or stops playing audio or video.
    public func setMediaActive(_ active: Bool) {
        guard active != mediaPlaying else { return }
        mediaPlaying = active
        if !active { mediaStoppedAt = uptime() }
        notifyExemption()
    }

    /// Whether this node plays media now or stopped less than `window` ago. Hidden-work rules exempt
    /// such a node, as Blink's `kRecentAudioDelay` (30 s) keeps a page that played audio from
    /// being throttled or frozen.
    public func mediaActiveWithin(_ window: Duration) -> Bool {
        if mediaPlaying { return true }
        guard let mediaStoppedAt else { return false }
        return uptime() - mediaStoppedAt < window
    }

    /// Calls `onChange` each time media starts or stops on this node or ``isCaptured`` changes: the
    /// inputs of the hidden-work exemptions, so a pending throttled deadline is placed again at once
    /// (Blink's `PageSchedulerImpl::AudioStateChanged` updates the policy of its throttled queues the
    /// same way). Hold the returned token as a ``subscribe(owner:_:)`` one.
    public func subscribeExemption(owner: String, _ onChange: @escaping @MainActor () -> Void) -> VisibilitySubscription {
        let subscription = VisibilitySubscription(owner: owner, node: self) { _ in onChange() }
        exemptionSubscriptions.removeAll { $0.subscription == nil }
        exemptionSubscriptions.append(WeakSubscription(subscription: subscription))
        return subscription
    }

    func notifyExemption() {
        exemptionSubscriptions.removeAll { $0.subscription == nil }
        let value = effective
        for subscription in exemptionSubscriptions.compactMap(\.subscription) where subscription.isActive {
            subscription.onFlip(value)
        }
    }
}

/// One vote on a node (``VisibilityNode/captureVote(reason:stayHidden:)``), as the node keeps it.
struct CaptureRecord {
    let id: UInt64
    let reason: String
    let stayHidden: Bool
}

/// A capture of a ``VisibilityNode``: the node renders while the vote holds, until ``release()``.
///
/// The vote keeps its node alive, and the node counts it, until the vote is released: call
/// ``release()`` when the capture ends (a screenshot's reply, a screencast's stop, a session's end),
/// as a ``FrameClient`` owner deactivates before it lets go. A vote has no deinit work.
@MainActor public final class VisibilityCaptureVote {
    /// Who captures (``VisibilityNode/captureReasons``).
    public let reason: String
    /// Whether the node keeps its ``VisibilityNode/effective`` state while it renders.
    public let stayHidden: Bool
    private let id: UInt64
    private var node: VisibilityNode?

    init(id: UInt64, reason: String, stayHidden: Bool, node: VisibilityNode) {
        self.id = id
        self.reason = reason
        self.stayHidden = stayHidden
        self.node = node
    }

    /// Whether ``release()`` ran.
    public var isReleased: Bool { node == nil }

    /// Ends this capture. The last vote's release stops the node rendering for capture, with one
    /// notice per subscriber. Idempotent.
    public func release() {
        guard let node else { return }
        self.node = nil
        node.releaseVote(id)
    }
}
