public import Foundation

/// What the Home UI asks the App to do. Every call is an intent; results come
/// back through the transcript source and the view model.
@MainActor
public protocol HomeActions: AnyObject {
    func send(text: String, replyTo: String?, in conversationID: String)
    func selectConversation(_ conversationID: String)
    func createConversation()
    func markRead(seq: Int, in conversationID: String)
    func retry(clientMsgID: String, in conversationID: String)
}
