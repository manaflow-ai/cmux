import Foundation

protocol SudoProcessInspecting: Sendable {
    func identity(for processIdentifier: Int32) -> SudoProcessIdentity?
    func executableURL(for processIdentifier: Int32) -> URL?
    func arguments(for processIdentifier: Int32) -> [String]?
    func directChildProcessIdentifiers(of processIdentifier: Int32) -> [Int32]
    func processGroupIdentifier(for processIdentifier: Int32) -> Int32?
    /// Returns all group members, or `nil` when the kernel inspection was incomplete.
    func processIdentifiers(inProcessGroup processGroupIdentifier: Int32) -> [Int32]?
    func allProcessIdentifiers() -> [Int32]
    func isRunning(_ identity: SudoProcessIdentity) -> Bool
}
