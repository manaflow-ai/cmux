import Foundation
import IOKit.pwr_mgt
import OSLog

nonisolated private let powerAssertionLog = Logger(subsystem: "com.cmuxterm.app", category: "power-assertion")

@MainActor
final class PowerAssertionHolder {
    typealias CreateAssertion = (CFString, String) -> (IOReturn, IOPMAssertionID)
    typealias ReleaseAssertion = (IOPMAssertionID) -> IOReturn

    private let type: CFString
    private let reason: String
    private let createAssertion: CreateAssertion
    private let releaseAssertion: ReleaseAssertion
    private var assertionID = IOPMAssertionID(0)

    var isHeld: Bool { assertionID != IOPMAssertionID(0) }

    convenience init(type: CFString, reason: String) {
        self.init(
            type: type,
            reason: reason,
            createAssertion: { type, reason in
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(
                    type,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason as CFString,
                    &id
                )
                return (result, id)
            },
            releaseAssertion: IOPMAssertionRelease
        )
    }

    init(
        type: CFString,
        reason: String,
        createAssertion: @escaping CreateAssertion,
        releaseAssertion: @escaping ReleaseAssertion
    ) {
        self.type = type
        self.reason = reason
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
    }

    func acquire() {
        guard !isHeld else { return }
        let (result, id) = createAssertion(type, reason)
        guard result == kIOReturnSuccess else {
            powerAssertionLog.error("Failed to acquire power assertion '\(self.reason, privacy: .public)' result=\(result)")
            return
        }
        assertionID = id
    }

    func release() {
        guard isHeld else { return }
        let id = assertionID
        assertionID = IOPMAssertionID(0)
        let result = releaseAssertion(id)
        if result != kIOReturnSuccess {
            powerAssertionLog.error("Failed to release power assertion '\(self.reason, privacy: .public)' result=\(result)")
        }
    }
}
