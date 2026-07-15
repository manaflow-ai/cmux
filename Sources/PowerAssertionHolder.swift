import Foundation
import IOKit.pwr_mgt

@MainActor
final class PowerAssertionHolder: PowerAssertionHolding {
    enum HolderError: Error { case createFailed(IOReturn) }

    private var assertionID = IOPMAssertionID(0)
    var isEnabled: Bool { assertionID != 0 }

    deinit {
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard enabled != isEnabled else { return }
        if enabled {
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "cmux remote keep-awake" as CFString,
                &newID
            )
            guard result == kIOReturnSuccess else { throw HolderError.createFailed(result) }
            assertionID = newID
        } else {
            let result = IOPMAssertionRelease(assertionID)
            guard result == kIOReturnSuccess else { throw HolderError.createFailed(result) }
            assertionID = IOPMAssertionID(0)
        }
    }
}
