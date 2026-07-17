import Foundation

protocol FeedScopedKeyboardFocusResponder: FeedKeyboardFocusResponder {
    var feedFocusScopeID: UUID { get }
}
