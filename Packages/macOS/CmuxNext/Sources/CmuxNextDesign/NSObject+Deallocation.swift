public import AppKit

// Looked up once rather than per call: `PointerHover.refresh(in:)` asks it on every refresh.
// crash-allow: ARC marks allowsWeakReference unavailable, so #selector cannot name it; NSObject always implements it.
private let allowsWeakReferenceSelector = NSSelectorFromString("allowsWeakReference")

extension NSObject {
    /// Whether the object is in deallocation now, so a `weak` reference to it aborts the runtime
    /// ("Cannot form weak reference to instance ... in the process of deallocation").
    ///
    /// A window that deallocates tears its views down, and a view that leaves it still reports the
    /// dying window as its `window`. Treat such a window as no window before storing it weakly:
    ///
    /// ```swift
    /// let window = view.window.flatMap { $0.isBeingDeallocated ? nil : $0 }
    /// ```
    ///
    /// The runtime's own test before it forms a weak reference (`-[NSObject allowsWeakReference]`,
    /// which ARC headers mark unavailable), called through its implementation.
    public var isBeingDeallocated: Bool {
        let selector = allowsWeakReferenceSelector
        guard let method = method(for: selector) else { return false }
        typealias AllowsWeakReference = @convention(c) (NSObject, Selector) -> Bool
        return !unsafeBitCast(method, to: AllowsWeakReference.self)(self, selector)
    }
}
