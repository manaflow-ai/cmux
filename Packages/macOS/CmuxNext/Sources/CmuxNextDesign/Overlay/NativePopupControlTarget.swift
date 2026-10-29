import AppKit

/// A control's target stays alive with the popup content that created it.
@MainActor
final class NativePopupControlTarget: NSObject {
    let action: (NSControl) -> Void

    init(_ action: @escaping (NSControl) -> Void) { self.action = action }

    @objc func perform(_ sender: NSControl) { action(sender) }
}
