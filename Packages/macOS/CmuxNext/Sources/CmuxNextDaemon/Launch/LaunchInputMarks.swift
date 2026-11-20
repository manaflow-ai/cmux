import CmuxNextCompat

/// The launch's first-interaction marks for a terminal (startup-tti: launch to the first key typed into a restored
/// terminal being echoed), on the launch marks' clock:
/// - `terminal_input_accepted`: the first input of this process went to a live attachment (after its replay, so the
///   daemon writes it to the terminal's PTY at once). Keys typed earlier were held (the window's key hold, then the
///   attach machine's queue) and this is when the first of them left the app.
/// - `terminal_echo`: the first live output any attachment decoded after that: the shell's echo of that input.
///
/// Each is marked once per process; after both, every call is one atomic load.
extension DaemonLaunchTimings {
    /// An attachment sent input to the daemon. `inputStage` 0: no input sent yet; 1: input sent, no output since;
    /// 2: both marked.
    func inputSent() {
        guard inputStage.load(ordering: .relaxed) == 0,
              inputStage.compareExchange(expected: 0, desired: 1, ordering: .relaxed).exchanged else { return }
        mark("terminal_input_accepted")
    }

    /// An attachment decoded live output (not a replay).
    func outputDecoded() {
        guard inputStage.load(ordering: .relaxed) == 1,
              inputStage.compareExchange(expected: 1, desired: 2, ordering: .relaxed).exchanged else { return }
        mark("terminal_echo")
    }
}
