extension BackingUpPairedMacStore {
    func scopeKey(account: String?, teamID: String?) async -> String? {
        guard let account else { return nil }
        return await nonoptionalScopeKey(account: account, teamID: teamID)
    }

    func nonoptionalScopeKey(account: String, teamID: String?) async -> String {
        let clientScope = await backup.clientScope() ?? ""
        guard !clientScope.isEmpty else {
            return "\(account)\u{0}\(teamID ?? "")"
        }
        return "\(account)\u{0}\(teamID ?? "")\u{0}\(clientScope)"
    }
}
