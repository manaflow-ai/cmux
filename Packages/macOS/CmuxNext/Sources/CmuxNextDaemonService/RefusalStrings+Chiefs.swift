public import Foundation

extension RefusalStrings {
    /// Make This Agent a Chief on a chat whose agent is in no local conversation yet (the owner
    /// adopts only an agent participant of one, `chief.profile.adopt`).
    public static var agentNotInConversation: String {
        text("handlers.refusal.agentNotInConversation", "This agent isn't in a conversation yet. Message it from Home first.")
    }

    /// Set My Picture… with a file over the owner's 1 MiB limit (`participant.avatar.set`).
    public static var pictureTooLarge: String {
        text("handlers.refusal.pictureTooLarge", "Choose a picture of 1 MB or less.")
    }
}
