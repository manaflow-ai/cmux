#if os(iOS)
import UIKit

@MainActor
final class ScrollDragSession: NSObject, UIDragSession {
    let dragItems: [UIDragItem]

    init(dragItems: [UIDragItem]) {
        self.dragItems = dragItems
    }

    var localContext: Any?
    var localDragSession: UIDragSession? { self }
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .default
    nonisolated var progress: Progress { Progress(totalUnitCount: 0) }
    var items: [UIDragItem] { dragItems }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { false }

    func location(in view: UIView) -> CGPoint { .zero }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(
        ofClass aClass: NSItemProviderReading.Type,
        completion: @escaping ([NSItemProviderReading]) -> Void
    ) -> Progress { Progress(totalUnitCount: 0) }
}
#endif
