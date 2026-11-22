import CmuxNextTabs

/// Tests name a tab by its id alone where one machine holds it, as the App never may (`AgentTabMap`):
/// the one key with that id, else the id on no machine.
extension AgentTabMap {
    subscript(_ key: String) -> Value? {
        get { self[onlyKey(ofTab: key) ?? AgentTabKey(machine: "", key: key)] }
        set { self[onlyKey(ofTab: key) ?? AgentTabKey(machine: "", key: key)] = newValue }
    }

    mutating func removeValue(forKey key: String) -> Value? {
        removeValue(forKey: onlyKey(ofTab: key) ?? AgentTabKey(machine: "", key: key))
    }
}
