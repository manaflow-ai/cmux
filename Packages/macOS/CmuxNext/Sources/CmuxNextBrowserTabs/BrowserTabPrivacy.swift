/// The browser data an approval tab can contribute to the rest of the app.
@MainActor
package struct BrowserTabPrivacy {
    private let isApproval: @MainActor (String) -> Bool

    package init(isApproval: @escaping @MainActor (String) -> Bool = { _ in false }) {
        self.isApproval = isApproval
    }

    package func permitsPersistence(for key: String, incognito: @autoclosure () -> Bool) -> Bool {
        !incognito() && !isApproval(key)
    }

    package func historySource<Value>(for key: String, _ source: @autoclosure () -> Value?) -> Value? {
        isApproval(key) ? nil : source()
    }

    package func permitsDuplication(of key: String) -> Bool { !isApproval(key) }
}
