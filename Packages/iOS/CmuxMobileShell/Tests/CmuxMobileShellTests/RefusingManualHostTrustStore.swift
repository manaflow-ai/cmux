import CmuxMobileShellModel

actor RefusingManualHostTrustStore: MobileManualHostTrustStoring {
    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        _ = scope
        return false
    }

    func trust(_ scope: MobileManualHostTrustScope) async {
        _ = scope
    }

    func removeAll() async {}
}
