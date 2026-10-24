import CoreFoundation

/// Runs main-actor work later in the current turn of the main run loop: a CFRunLoop block in the
/// common modes (a menu's or a drag's tracking loop runs it too). The run loop runs it after the
/// event or source it is handling and before it waits, so before that turn's Core Animation commit;
/// work enqueued inside the commit's own layout pass runs on the next turn, which the wake-up starts.
nonisolated struct MainRunLoopTurn: Sendable {
    func perform(_ work: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            // main-proof: a CFRunLoopGetMain() block runs on the main thread
            MainActor.assumeIsolated { work() }
        }
        CFRunLoopWakeUp(main)
    }
}
