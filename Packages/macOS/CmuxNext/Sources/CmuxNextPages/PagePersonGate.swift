public import Foundation

extension PageCallContext {
    /// SECURITY: this call counts only when the person's own click or key in `page` backs it: a gesture
    /// came with it, and `backs` (the HID system's input, the app's `PersonInputLedger`) says that gesture
    /// was the person's, never a click or key another process posted (a Computer Use agent driving cmux).
    /// `claim`, when given, spends the gesture once. Otherwise throws `refusal`.
    @MainActor public func requirePerson(on page: String, backs: (@MainActor (TimeInterval) -> Bool)?, refusal: PageError,
                                         claim: (@MainActor (TimeInterval) -> Bool)? = nil) throws {
        guard self.page == page, userGesture, let event = gestureEvent, backs?(event) == true,
              claim?(event) ?? true else { throw refusal }
    }
}
