extension SettingsController {
    /// Effective, validated values sent to the local acpmux daemon.
    public var chatSettings: ChatSettings {
        ChatSettings(effective: snapshot.root, file: fileRoot, managedRoots: managedChatRoots)
    }

    /// Rows preserve refused values so a person can see the reason and remove their own entry.
    public var chatRootRows: JSONValue {
        let validator = ChatRootValidator()
        let user = ChatSettings.strings(fileRoot.value(at: ChatSettings.rootsPath))
        return .array(ChatSettings.unique(user + managedChatRoots).map { path in
            ["path": .string(path), "managed": .bool(managedChatRoots.contains(path)),
             "reason": validator.refusal(path).map(JSONValue.string) ?? .null]
        })
    }
}
