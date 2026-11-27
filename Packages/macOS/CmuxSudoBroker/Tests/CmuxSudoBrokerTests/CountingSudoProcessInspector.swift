@testable import CmuxSudoBroker
import Foundation
import os

/// Counts descendant scans for a stable synthetic process generation chain.
final class CountingSudoProcessInspector: SudoProcessInspecting, @unchecked Sendable {
    private let identitiesByProcessIdentifier: [Int32: SudoProcessIdentity]
    private let childrenByProcessIdentifier: [Int32: [Int32]]
    // The protocol is synchronous; the lock makes the observable counter safe
    // when a test runner invokes the fixture from a different executor.
    private let queryCount = OSAllocatedUnfairLock(initialState: 0)

    init(chain: [SudoProcessIdentity]) {
        identitiesByProcessIdentifier = Dictionary(
            uniqueKeysWithValues: chain.map { ($0.processIdentifier, $0) }
        )
        childrenByProcessIdentifier = Dictionary(
            uniqueKeysWithValues: chain.enumerated().map { index, identity in
                let children = index + 1 < chain.count
                    ? [chain[index + 1].processIdentifier]
                    : []
                return (identity.processIdentifier, children)
            }
        )
    }

    var directChildQueryCount: Int {
        queryCount.withLock { $0 }
    }

    func identity(for processIdentifier: Int32) -> SudoProcessIdentity? {
        identitiesByProcessIdentifier[processIdentifier]
    }

    func executableURL(for processIdentifier: Int32) -> URL? { nil }

    func arguments(for processIdentifier: Int32) -> [String]? { nil }

    func directChildProcessIdentifiers(of processIdentifier: Int32) -> [Int32] {
        queryCount.withLock { $0 += 1 }
        return childrenByProcessIdentifier[processIdentifier] ?? []
    }

    func processGroupIdentifier(for processIdentifier: Int32) -> Int32? {
        identitiesByProcessIdentifier[processIdentifier] == nil ? nil : 10_000
    }

    func processIdentifiers(inProcessGroup processGroupIdentifier: Int32) -> [Int32]? {
        processGroupIdentifier == 10_000
            ? Array(identitiesByProcessIdentifier.keys)
            : []
    }

    func allProcessIdentifiers() -> [Int32] {
        Array(identitiesByProcessIdentifier.keys)
    }

    func isRunning(_ identity: SudoProcessIdentity) -> Bool {
        identitiesByProcessIdentifier[identity.processIdentifier] == identity
    }
}
