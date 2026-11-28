import CMUXMobileCore

extension MobileIOSBuildScope {
    /// Names every computer keyed in `names` for this build, leaving external
    /// hosts (Cloud machines) as they are: the build tag scopes which Mac a
    /// dev phone pairs with, and no tag scopes a Cloud machine.
    func computerDisplayNames(
        _ names: [String: String],
        isExternalHost: (String) -> Bool
    ) -> [String: String] {
        var scoped = names
        for (id, name) in names where !isExternalHost(id) {
            scoped[id] = computerDisplayName(name)
        }
        return scoped
    }
}
