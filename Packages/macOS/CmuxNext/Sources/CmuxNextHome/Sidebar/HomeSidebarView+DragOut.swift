public import AppKit
public import CmuxHomeCore
import MessagesLabSidebar

extension HomeSidebarView {
    /// A conversation's row or tile drag left the list sideways (the pointer on screen): `take` returning true
    /// takes it over (the Chief dragged into the app's sidebar, `ChiefDragSession`); false, or a teammate row,
    /// and the list puts its drag back.
    public func setDragOut(_ take: @escaping (ConversationID, CGPoint) -> Bool) {
        list.onDragOut = { [weak self] id, point in
            guard let self, teammate(for: id) == nil else { return false }
            return take(ConversationID(id), point)
        }
    }
}
