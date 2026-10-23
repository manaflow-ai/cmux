import AppKit
import CmuxNextHome
import CmuxNextHomeEngine

extension TopHomePageView {
    /// Home's Chief conversation: the Chief placed on a server takes over a local one without history
    /// (`HomeChiefSource`).
    static func chief(_ home: HomeService) -> String? {
        let local = HomeChiefName.select(from: home.conversations)
        return home.tabChiefs.chiefTab(local: local?.id, localHasHistory: (local?.lastSeq ?? 0) > 0, choice: home.hostedChief.choice)
    }

    /// The Chief's row dragged out of the list sideways goes on as a drag into a window's sidebar, where its drop
    /// adds the Chief item (Leo 2026-10-21: drag in a Chief, like a special workspace). Any other row stays Home's.
    func wireChiefDrag(services: AppServices) {
        list.setDragOut { [weak services] id, point in
            guard let services, id.rawValue == Self.chief(services.home) else { return false }
            return ChiefDragSession.begin(services: services, screenPoint: point)
        }
    }
}
