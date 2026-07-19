@testable import CmuxMobileRPC

actor SendAuthorizationInvocationRecorder {
    private var count = 0

    func authorize() -> MobileRPCSendLease {
        count += 1
        return MobileRPCSendLease()
    }

    func invocationCount() -> Int {
        count
    }
}
