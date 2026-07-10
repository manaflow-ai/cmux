@testable import CmuxMobileRPC

actor SendAuthorizationInvocationRecorder {
    private var count = 0

    func authorize() -> MobileRPCAuthScope.SendLease {
        count += 1
        return MobileRPCAuthScope.SendLease()
    }

    func invocationCount() -> Int {
        count
    }
}
