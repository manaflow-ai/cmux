public import Foundation

/// Transfer to This Mac's decisions that need no app state (the App's `CloudTransferLocal`).
public struct CloudTransferRules {
    public init() {}

    /// Whether `machine` is the signed-in person's own (`user`): they created it, or it is a
    /// personal machine (no team) whose record names no creator. Anyone else's chat comes over as
    /// the person's own copy of its folder and stays with its owner.
    public static func isOwner(_ machine: CloudMachine, user: String?) -> Bool {
        guard let creator = machine.createdBy, !creator.isEmpty else { return machine.team == nil }
        return creator == user
    }

    /// A folder that does not exist yet: `<home>/<base>/<name>`, else `<name> 2`, `<name> 3`...
    public static func newFolder(named name: String, base: String, home: String, exists: (String) -> Bool) -> String {
        let root = (home as NSString).appendingPathComponent(base)
        let plain = name.isEmpty || name == "/" ? "Cloud chat" : name
        var candidate = (root as NSString).appendingPathComponent(plain)
        var number = 2
        while exists(candidate) {
            candidate = (root as NSString).appendingPathComponent("\(plain) \(number)")
            number += 1
        }
        return candidate
    }

    /// The chat's folder here: `local` plus the chat's place under the folder the fetch copied.
    public static func localChat(local: String, remoteChat: String, remoteRoot: String?) -> (root: String, chat: String) {
        let root = remoteRoot ?? remoteChat
        let sub = remoteChat == root || !remoteChat.hasPrefix(root + "/") ? "" : String(remoteChat.dropFirst(root.count + 1))
        return (root, sub.isEmpty ? local : (local as NSString).appendingPathComponent(sub))
    }
}
