import Foundation

/// How long a terminal test waits for something that happens unless the code
/// is broken: a screen drawing its text, the probe counting parsed bytes, the
/// projection's reset arriving.
///
/// The kit job's iOS simulator shares its Mac with other jobs, and the kit's
/// own suites share the main actor. Per-call bounds of 0.5 to 3 s held on an
/// idle Mac and failed at random under load, a different test each run
/// (cmux#64874's ios fast verdict, run 46172907187 job 141065368904:
/// BenchProbeAccounting's echo after 1 s, ProjectionScrollback's reset after
/// 3 s). A wait returns as soon as its condition holds, so a passing run
/// costs nothing more; the bound only decides how long a broken run waits
/// before it fails. What each test asserts after its wait is unchanged.
enum TerminalTestWait {
    /// The least any wait on a real state predicate polls for, in seconds.
    static let loadFloor: Double = 10

    /// Polls `condition` until it holds or `max(seconds, loadFloor)` passes.
    static func until(
        _ seconds: Double = loadFloor,
        isolation: isolated (any Actor)? = #isolation,
        _ condition: () -> Bool
    ) async throws {
        let bound = max(seconds, loadFloor)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(bound * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls a real state predicate until a deadline
        }
    }
}
