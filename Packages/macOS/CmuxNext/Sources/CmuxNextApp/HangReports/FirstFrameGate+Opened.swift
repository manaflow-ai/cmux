extension FirstFrameGate {
    /// Returns once the gate is open (at once when it already is).
    func opened() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in whenOpen { done.resume() } }
    }
}
