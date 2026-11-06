// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextDictation
import Foundation

/// Share Screen with Chief's capture host while none exists: the cmux Computer Use helper read
/// the screen for it, and that helper is gone (its engine now runs in cmux Remote's Computer Use
/// worker, which serves agents, not this app). Every call says no host answers, which the share
/// shows as unavailable and checks again later; it never asks macOS for Screen Recording for cmux.
nonisolated struct ChiefScreenStillsUnavailable: ChiefScreenCaptureHost {
    struct Gone: Error, Equatable {}

    @concurrent func screenRecordingAllowed() async throws -> Bool { throw Gone() }
    @concurrent func requestScreenRecording() async throws { throw Gone() }
    @concurrent func displayStill(_ arguments: [String: Any]) async throws -> [String: Any] { throw Gone() }
    func isHelperGone(_ error: any Error) -> Bool { error is Gone }
    func refusal(_ error: any Error) -> String? { nil }
}
