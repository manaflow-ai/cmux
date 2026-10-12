import Foundation

/// EXPERIMENT (cx-z9kz0): one run-loop pass at the end of didFinishLaunching, so WebKit's
/// pending main-thread work (the first agent page's process and navigation) runs before
/// the windows' first-frame jobs drain the main queue.
enum LaunchRunLoopTurn {
    static func give() {
        DebugTimings.markLaunch("exp.turn_start")
        RunLoop.current.run(mode: .default, before: Date())
        DebugTimings.markLaunch("exp.turn_end")
    }
}
