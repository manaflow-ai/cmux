import AppKit
import Bonsplit
import Observation
import SwiftUI


// MARK: - Notifications popover visibility state & change broadcast
extension Notification.Name {
    static let cmuxNotificationsPopoverVisibilityDidChange = Notification.Name("cmux.notificationsPopoverVisibilityDidChange")
}

private enum NotificationsPopoverVisibilityUserInfoKey {
    static let isShown = "isShown"
    static let windowNumber = "windowNumber"
}

@Observable
final class NotificationsPopoverVisibilityState {
    static let shared = NotificationsPopoverVisibilityState()

    private(set) var isShown = false
    private(set) var shownWindowNumbers: Set<Int> = []
    private var shownPopoverIDs: Set<ObjectIdentifier> = []
    private var shownPopoverWindowNumbers: [ObjectIdentifier: Int] = [:]
    private var sourceLessShown = false

    private init() {}

    func setShown(_ newValue: Bool, source: AnyObject?, windowNumber: Int? = nil) {
        if Thread.isMainThread {
            setShownOnMain(newValue, source: source, windowNumber: windowNumber)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setShown(newValue, source: source, windowNumber: windowNumber)
            }
        }
    }

    func isShown(in windowNumber: Int?) -> Bool {
        guard let windowNumber else { return isShown }
        return sourceLessShown || shownWindowNumbers.contains(windowNumber)
    }

    private func setShownOnMain(_ newValue: Bool, source: AnyObject?, windowNumber: Int?) {
        if let source {
            let id = ObjectIdentifier(source)
            if newValue {
                shownPopoverIDs.insert(id)
                if let windowNumber {
                    shownPopoverWindowNumbers[id] = windowNumber
                }
            } else {
                shownPopoverIDs.remove(id)
                shownPopoverWindowNumbers.removeValue(forKey: id)
            }
        } else {
            shownPopoverIDs.removeAll()
            shownPopoverWindowNumbers.removeAll()
            sourceLessShown = newValue
        }
        updateShown()
    }

    private func updateShown() {
        let newWindowNumbers = Set(shownPopoverWindowNumbers.values)
        if shownWindowNumbers != newWindowNumbers {
            shownWindowNumbers = newWindowNumbers
        }
        let newValue = sourceLessShown || !shownPopoverIDs.isEmpty
        guard isShown != newValue else { return }
        isShown = newValue
    }

    #if DEBUG
    func resetForTesting() {
        shownPopoverIDs.removeAll()
        shownPopoverWindowNumbers.removeAll()
        sourceLessShown = false
        updateShown()
    }
    #endif
}

func postNotificationsPopoverVisibilityDidChange(isShown: Bool, source: AnyObject? = nil, windowNumber: Int? = nil) {
    let state = NotificationsPopoverVisibilityState.shared
    state.setShown(isShown, source: source, windowNumber: windowNumber)
    var userInfo: [String: Any] = [NotificationsPopoverVisibilityUserInfoKey.isShown: state.isShown]
    if let windowNumber {
        userInfo[NotificationsPopoverVisibilityUserInfoKey.windowNumber] = windowNumber
    }
    NotificationCenter.default.post(
        name: .cmuxNotificationsPopoverVisibilityDidChange,
        object: nil,
        userInfo: userInfo
    )
}

