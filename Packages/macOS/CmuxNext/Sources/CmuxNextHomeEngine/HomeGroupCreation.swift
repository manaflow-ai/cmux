public import CmuxHomeCore
public import CmuxNextHome

/// What `cmux chat create` (``HomeGroupActions/create(named:title:replies:)``) ended with.
public enum HomeGroupCreation: Hashable, Sendable {
    /// The group exists (and its Chiefs Reply setting, when one was asked for, was taken).
    case created(ConversationID)
    /// Nothing was made, or the setting was refused after the group was made: why.
    case refused(HomeGroupOutcome)
}
