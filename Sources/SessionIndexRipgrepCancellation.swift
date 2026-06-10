import AppKit
import Bonsplit
import CMUXAgentLaunch
import Combine
import Darwin
import Foundation
import os
import SQLite3


/// Locked cancellation state shared by synchronous `Process` callbacks.
/// `onCancel` cannot await an actor, so mutable state stays behind `lock`.
final class SessionIndexRipgrepCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let sendSignal: @Sendable (pid_t, Int32) -> Int32
    private var activeProcessIdentifier: pid_t?
    private var finishedProcessIdentifier: pid_t?

    init(sendSignal: @escaping @Sendable (pid_t, Int32) -> Int32 = Darwin.kill) {
        self.sendSignal = sendSignal
    }

    func markStarted(processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        if finishedProcessIdentifier == processIdentifier {
            activeProcessIdentifier = nil
        } else {
            activeProcessIdentifier = processIdentifier
        }
    }

    func markFinished(processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        finishedProcessIdentifier = processIdentifier
        if activeProcessIdentifier == processIdentifier {
            activeProcessIdentifier = nil
        }
    }

    func cancel() {
        lock.lock()
        let processIdentifier = activeProcessIdentifier
        activeProcessIdentifier = nil
        lock.unlock()

        guard let processIdentifier else { return }
        _ = sendSignal(processIdentifier, SIGTERM)
    }
}

// MARK: - Parsed metadata cache

