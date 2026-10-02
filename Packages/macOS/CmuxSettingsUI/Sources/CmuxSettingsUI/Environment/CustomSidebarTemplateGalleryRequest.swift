import AppKit

/// Coordinates one pending request to present the custom-sidebar template gallery.
@MainActor
public final class CustomSidebarTemplateGalleryRequest {
    private var pending = false

    public init() {}

    /// Marks the gallery for presentation and notifies mounted settings views.
    public func request() {
        pending = true
        NotificationCenter.default.post(name: .customSidebarTemplateGalleryRequested, object: nil)
    }

    /// Consumes the pending presentation request, if one exists.
    public func consume() -> Bool {
        guard pending else { return false }
        pending = false
        return true
    }
}
