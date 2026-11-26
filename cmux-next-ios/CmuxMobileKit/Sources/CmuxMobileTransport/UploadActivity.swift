import Foundation

/// An attachment upload's acked bytes advanced: bytes heard from the Mac, so the link is making
/// progress, and a chat prompt the outbox holds keeps going (Leo, 2026-11-24: "if it's making good
/// progress, it shiukd be allowed to keep going?"). `AttachmentUploadClient` calls ``advanced()``
/// where the upload engine exists; each `AcpmuxHub` listens and tells its chats' outboxes.
@MainActor
public enum UploadActivity {
    /// When an upload last advanced; nil until one does.
    public private(set) static var lastAdvance: ContinuousClock.Instant?
    private static var listeners: [ObjectIdentifier: @MainActor () -> Void] = [:]

    public static func advanced() {
        lastAdvance = .now
        for listener in listeners.values { listener() }
    }

    /// `owner` hears every advance until ``stopListening(_:)``.
    public static func listen(_ owner: AnyObject, _ body: @escaping @MainActor () -> Void) {
        listeners[ObjectIdentifier(owner)] = body
    }

    public static func stopListening(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
    }
}
