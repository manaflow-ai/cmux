import AppKit
import Foundation

/// Stable identity captured for a computer-use target before exposing focus actions.
struct ComputerUseTargetIdentity: Equatable, Sendable {
    let processIdentifier: Int
    let bundleIdentifier: String
    let launchDate: Date

    init?(
        state: ComputerUseDriverState,
        runningApplication: NSRunningApplication
    ) {
        guard !runningApplication.isTerminated,
              Int(runningApplication.processIdentifier) == state.targetPID,
              let bundleIdentifier = runningApplication.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              let launchDate = runningApplication.launchDate,
              launchDate <= state.lastActionAt,
              runningApplication.localizedName == state.targetApp
        else {
            return nil
        }

        self.processIdentifier = state.targetPID
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
    }

    init(processIdentifier: Int, bundleIdentifier: String, launchDate: Date) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
    }

    func matches(
        processIdentifier: Int,
        bundleIdentifier: String?,
        launchDate: Date?
    ) -> Bool {
        processIdentifier == self.processIdentifier
            && bundleIdentifier == self.bundleIdentifier
            && launchDate == self.launchDate
    }

    @MainActor
    func matches(_ runningApplication: NSRunningApplication?) -> Bool {
        guard let runningApplication, !runningApplication.isTerminated else { return false }
        return matches(
            processIdentifier: Int(runningApplication.processIdentifier),
            bundleIdentifier: runningApplication.bundleIdentifier,
            launchDate: runningApplication.launchDate
        )
    }
}
