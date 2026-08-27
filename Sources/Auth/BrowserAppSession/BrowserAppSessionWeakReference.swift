/// A non-owning reference used by the app-session storage registry.
final class BrowserAppSessionWeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
