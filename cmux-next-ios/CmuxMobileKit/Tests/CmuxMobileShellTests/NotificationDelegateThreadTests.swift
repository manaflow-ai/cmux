import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileShell

#if os(iOS)
/// TestFlight 1.2.0 (20261023213712) crashed on every notification tap (crash
/// submission ADgp1IfhG3RNLXEsrIVTKbE, SIGABRT in
/// `-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]` under
/// `@objc closure #1 in CmuxMobileAppDelegate.userNotificationCenter(_:didReceive:)`).
/// The delegate used the `async` form: Swift's @objc thunk calls UIKit's
/// completion handler wherever the async body returns, a background thread,
/// and UIKit aborts updating the app snapshot there. These call the delegate
/// the way UIKit does, through the Objective-C selector, and require the
/// handler on the main thread.
@MainActor @Suite(.timeLimit(.minutes(1))) struct NotificationDelegateThreadTests {
    static let didReceive = NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")
    static let willPresent = NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")

    /// A placeholder center: the delegate never messages it, and
    /// `UNUserNotificationCenter.current()` needs an app bundle a test host lacks.
    /// `takeUnretainedValue` leaks alloc's +1 on purpose: the object is never
    /// initialized, so it must never be deallocated (not `takeRetainedValue`).
    func center() throws -> UNUserNotificationCenter {
        let any = (UNUserNotificationCenter.self as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        return try #require(any as? UNUserNotificationCenter)
    }

    /// A notification as iOS hands it over (no cmuxMobile route, so the tap opens nothing).
    func notification() throws -> UNNotification {
        let content = UNMutableNotificationContent()
        content.title = "Terminal"
        content.userInfo = ["test": "thread"]
        let request = UNNotificationRequest(identifier: "thread-test", content: content, trigger: nil)
        try #require((UNNotification.self as AnyObject).responds(to: NSSelectorFromString("notificationWithRequest:date:")))
        let made = (UNNotification.self as AnyObject).perform(NSSelectorFromString("notificationWithRequest:date:"), with: request, with: Date())
        return try #require(made?.takeUnretainedValue() as? UNNotification)
    }

    func response(actionIdentifier: String = UNNotificationDefaultActionIdentifier) throws -> UNNotificationResponse {
        try #require((UNNotificationResponse.self as AnyObject).responds(to: NSSelectorFromString("responseWithNotification:actionIdentifier:")))
        let made = (UNNotificationResponse.self as AnyObject).perform(NSSelectorFromString("responseWithNotification:actionIdentifier:"),
                                                                       with: try notification(), with: actionIdentifier)
        return try #require(made?.takeUnretainedValue() as? UNNotificationResponse)
    }

    @Test func aTapCallsUIKitsHandlerOnTheMainThread() async throws {
        let delegate: any UNUserNotificationCenterDelegate = CmuxMobileAppDelegate()
        // The handler form must be what UIKit calls; otherwise `?.` below does nothing and the test would hang.
        try #require((delegate as AnyObject).responds(to: Self.didReceive))
        let center = try center()
        let response = try response()
        let onMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            delegate.userNotificationCenter?(center, didReceive: response) { done.resume(returning: Thread.isMainThread) }
        }
        #expect(onMain, "UIKit aborts when this handler runs off the main thread")
    }

    @Test func aDismissCallsUIKitsHandlerOnTheMainThread() async throws {
        let delegate: any UNUserNotificationCenterDelegate = CmuxMobileAppDelegate()
        // The handler form must be what UIKit calls; otherwise `?.` below does nothing and the test would hang.
        try #require((delegate as AnyObject).responds(to: Self.didReceive))
        let center = try center()
        let response = try response(actionIdentifier: UNNotificationDismissActionIdentifier)
        let onMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            delegate.userNotificationCenter?(center, didReceive: response) { done.resume(returning: Thread.isMainThread) }
        }
        #expect(onMain)
    }

    @Test func aPushInFrontCallsUIKitsHandlerOnTheMainThread() async throws {
        let delegate: any UNUserNotificationCenterDelegate = CmuxMobileAppDelegate()
        try #require((delegate as AnyObject).responds(to: Self.willPresent))
        let center = try center()
        let notification = try notification()
        let (onMain, options) = await withCheckedContinuation { (done: CheckedContinuation<(Bool, UNNotificationPresentationOptions), Never>) in
            delegate.userNotificationCenter?(center, willPresent: notification) { done.resume(returning: (Thread.isMainThread, $0)) }
        }
        #expect(onMain, "UIKit's presentation handler must run on the main thread")
        #expect(options == [.banner, .list, .sound])
    }
}
#endif
