import Bonsplit
import Foundation

/// Registration identity retained while a Cloud tree drag owns AppKit.
@MainActor
extension CloudTreeOutlineView.Coordinator {
    typealias ActiveDrag = CloudTreeDragRegistration
}
