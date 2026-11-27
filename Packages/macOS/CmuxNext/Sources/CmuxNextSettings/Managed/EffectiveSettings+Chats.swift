extension EffectiveSettings {
    /// Chats deliberately do not use generic forced replacement: roots are additive and switches
    /// can only be forced off. Preserve provenance even when a user root is also managed.
    mutating func mergeChats(managed: ManagedPreferences, team: TeamPolicyLayer) {
        let rootsKey = "agents.chats.roots"
        managedChatRoots = ChatSettings.unique(
            ChatSettings.strings(team.defaults[rootsKey]) + ChatSettings.strings(managed.recommended[rootsKey])
                + ChatSettings.strings(team.enforced[rootsKey]) + ChatSettings.strings(managed.forced[rootsKey]))
        let userRoots = ChatSettings.strings(fileRoot.value(at: ChatSettings.rootsPath))
        if !managedChatRoots.isEmpty || fileRoot.value(at: ChatSettings.rootsPath) != nil {
            root = root.setting(.array(ChatSettings.unique(userRoots + managedChatRoots).map(JSONValue.string)), at: ChatSettings.rootsPath)
        }
        for key in ChatSettings.booleanKeys {
            let path = Self.path(key)
            let user = fileRoot.value(at: path)?.boolValue
                ?? managed.recommended[key]?.boolValue ?? team.defaults[key]?.boolValue ?? true
            let deviceOff = managed.forced[key]?.boolValue == false
            let teamOff = team.enforced[key]?.boolValue == false
            if user == false || deviceOff || teamOff || fileRoot.value(at: path) != nil {
                root = root.setting(.bool(user && !deviceOff && !teamOff), at: path)
            }
            if deviceOff { managedKeys[key] = .device }
            else if teamOff { managedKeys[key] = .team(team.teamName) }
        }
    }
}
